// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import SwiftUI
import Combine
import OSLog

/// THE playlist flow. One entry point, one sheet, one create dialog, for
/// both worlds.
///
/// Before this there were three ways in (a music-tab alert, a server-only
/// sheet, a device-only menu) and four create dialogs; which world a list
/// ended up in depended on which surface you happened to long-press. The
/// worlds still differ. A server playlist can only hold what the server owns.
/// But that is now a stated choice in ONE place instead of a property of
/// the route you took.
///
/// A button inside a `contextMenu` or a swipe action can only flip a state:
/// the presentation must hang OUTSIDE it, because the menu's hierarchy is
/// torn down when it closes and a sheet attached there is never presented.
/// So the button only asks, this type holds the state, and `RootView`
/// presents. Creating from inside the sheet PUSHES (no sheet over sheet).
@MainActor
final class PlaylistPresenter: ObservableObject {
    static let shared = PlaylistPresenter()
    private init() {}

    /// The device lists, for adding and creating.
    private var lists: MaerPlaylists { .shared }

    /// Entries looking for a home. The titles travel WITH the ids: the
    /// surface had the name on screen at the moment of the tap, the resolving
    /// routine may not (cold catalogue cache).
    struct AddRequest: Identifiable {
        let ids: [String]
        let titles: [String: String]
        var id: String { ids.joined(separator: "|") }
    }

    /// A new list, optionally with entries to put into it right away.
    struct CreateRequest: Identifiable {
        var place: PlaylistPlace
        /// What may be chosen. One place means no choice is shown.
        var places: [PlaylistPlace]
        /// The servers a server list may be made on: one for entries of one
        /// server, every active one for an empty list (then the form asks
        /// "Where?" per server).
        var servers: [MusicSourceRule.Server] = []
        var ids: [String] = []
        var titles: [String: String] = [:]
        let id = UUID()
    }

    @Published var adding: AddRequest?
    @Published var creating: CreateRequest?
    @Published var message: String?
    /// A followed show whose rule just went into a list, while its
    /// downloads are off (`RoutinePlayback.autoDownloadOffer`).
    @Published var offeringAutoDownload: PodcastShow?

    /// WHICH hierarchy has to present. A sheet cannot be presented from the
    /// root while another sheet is already up, so a surface living inside one
    /// (the queue, the player) carries its own presentation host and stamps
    /// its requests with it. The root host then stays out of the way. The
    /// stamp travels through the environment, so no call site has to know
    /// where it is being shown.
    @Published private(set) var host: UUID = PlaylistHostID.root

    func askToAdd(_ ids: [String], titles: [String: String] = [:],
                  host: UUID = PlaylistHostID.root) {
        self.host = host
        adding = AddRequest(ids: ids, titles: titles)
    }

    /// The one create entry. `place` is what the calling surface means (the
    /// row card of that world); the choice stays visible so it can be changed.
    func askToCreate(place: PlaylistPlace = .device,
                     ids: [String] = [], titles: [String: String] = [:],
                     host: UUID = PlaylistHostID.root) {
        self.host = host
        let places = Self.places(for: ids)
        creating = CreateRequest(place: places.contains(place) ? place : .device,
                                 places: places, servers: Self.servers(for: ids), ids: ids, titles: titles)
    }

    /// Which worlds these entries may go to. With nothing selected (creating
    /// an empty list) both stand, as far as a server exists at all.
    static func places(for ids: [String]) -> [PlaylistPlace] {
        PlaylistDestination.places(servers: servers(for: ids))
    }

    /// The servers these entries may be filed on: each entry's server by
    /// its namespace, never the device's choice (`PlaylistDestination`).
    static func servers(for ids: [String]) -> [MusicSourceRule.Server] {
        PlaylistDestination.servers(active: AppSession.shared.activeMusicServers,
                                    owners: ids.map(MusicSourceRule.owner))
    }

    /// Entries of two servers at once, for the sentence in the sheet.
    static func mixesServers(_ ids: [String]) -> Bool {
        PlaylistDestination.mixesServers(ids.map(MusicSourceRule.owner))
    }

    // MARK: - Doing it

    func addToDevice(_ ids: [String], titles: [String: String],
                     listId: String, listName: String) async {
        let expanded = await Self.expandedForDevice(ids, titles: titles)
        let outcome = lists.add(itemIds: expanded.ids, to: listId, knownTitles: expanded.titles)
        message = Self.text(for: outcome, listName: listName)
        if outcome == .added { offeringAutoDownload = RoutinePlayback.autoDownloadOffer(for: expanded.ids) }
    }

    /// The server states which songs an item contributes. An album expands
    /// there exactly as it does here.
    func addToServer(_ ids: [String], playlistItemId: String) async -> Bool {
        // The TARGET decides, not the device: the songs are written into
        // THIS playlist's server, and expanding an album against another
        // one would answer with nothing.
        let music = AppSession.shared.musicProvider(for: playlistItemId)
        var songIds: [String] = []
        for id in ids { songIds.append(contentsOf: await music.songIds(forItemId: id)) }
        guard !songIds.isEmpty else {
            message = String(localized: "Nothing to add.")
            return false
        }
        do {
            try await music.addSongs(songIds, toPlaylistItemId: playlistItemId)
            music.librarySynced.send()
            return true
        } catch {
            Logger.library.error("PLAYLIST server add failed reason=\(FailureReason.of(error), privacy: .public)")
            message = String(localized: "Could not add to the playlist.")
            return false
        }
    }

    /// Create in the chosen world and put the carried entries in. Returns
    /// false when the server refused. The caller then keeps the form open.
    func create(name rawName: String, place: PlaylistPlace, server: MusicSourceRule.Server?,
                ids: [String], titles: [String: String]) async -> Bool {
        let trimmed = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = trimmed.isEmpty ? String(localized: "Playlist") : trimmed
        switch place {
        case .device:
            let list = lists.create(name: name)
            if !ids.isEmpty {
                await addToDevice(ids, titles: titles, listId: list.id, listName: name)
            }
            return true
        case .server:
            // The chosen server, never "the music provider": with two
            // servers that is the union, which has no one place to create in.
            // With one it is the same provider as before.
            guard let server else {
                message = String(localized: "Could not create the playlist.")
                return false
            }
            let music = AppSession.shared.musicProvider(serving: .one(server))
            guard let playlistItemId = try? await music.createPlaylist(name: name) else {
                message = String(localized: "Could not create the playlist.")
                return false
            }
            // The row is server truth. Without this the new list appears
            // only after the next sync.
            music.librarySynced.send()
            guard !ids.isEmpty else { return true }
            return await addToServer(ids, playlistItemId: playlistItemId)
        }
    }

    // MARK: - Expansion (device world)

    /// Playlists are SONGS, not albums: a container lands as its tracks, a
    /// WORK (reading, radio play) stays ONE entry.
    /// `PlaylistDestination.expansion` decides; this routine only fetches
    /// what the decision asks for.
    ///
    /// The catalogue provider grew out of the AUDIOBOOK path, where one id IS
    /// the whole work. The playlist add inherited that assumption and asked
    /// the form switch only for catalogue ids, never for a server album.
    static func expandedForDevice(_ ids: [String],
                                  titles carried: [String: String] = [:]) async -> (ids: [String], titles: [String: String]) {
        var out: [String] = []
        var titles = carried
        for id in ids {
            // The id carries its source; the device's choice does not.
            let music = AppSession.shared.musicProvider(for: id)
            let kind = music.owns(itemId: id) ? music.kind(of: id) : nil
            switch PlaylistDestination.expansion(for: id, serverKind: kind) {
            case .asIs:
                out.append(id)
            case .serverContainer:
                let songs = await music.songItems(forItemId: id)
                guard !songs.isEmpty else { out.append(id); continue }
                for song in songs {
                    out.append(song.id)
                    if let title = MaerPlaylists.usableTitle(song.title, for: song.id) {
                        titles[song.id] = title
                    }
                }
            case .catalogRelease:
                let expanded = await expandedCatalogRelease(id)
                out.append(contentsOf: expanded.ids)
                titles.merge(expanded.titles) { old, _ in old }
            }
        }
        return (out, titles)
    }

    /// The catalogue's album/work switch. A release only expands when the
    /// form says "album" AND it really carries several tracks.
    /// The detail is asked of `router`, the form of `archiveForm` (the
    /// catalogue's register, which that detail fills); both are the live ones
    /// by default, a witness hands in its own.
    static func expandedCatalogRelease(_ id: String, router: ItemRouter = .live,
                                       archiveForm: (String) -> ArchiveItemForm? = {
                                           FreeCatalogProvider.shared.archiveForm(itemId: $0)
                                       }) async -> (ids: [String], titles: [String: String]) {
        let source = router.provider(id)
        var form = archiveForm(id)
        if form == nil {
            // The form is only known once the detail was seen. Ask for it
            // rather than guessing from the id.
            _ = try? await source.fetchItemDetail(itemId: id)
            form = archiveForm(id)
        }
        guard form == .album,
              let detail = try? await source.fetchItemDetail(itemId: id),
              let tracks = detail.media.tracks, tracks.count > 1 else {
            return ([id], [:])
        }
        var ids: [String] = []
        var titles: [String: String] = [:]
        for index in tracks.indices {
            let songId = CatalogSongID.make(album: id, index: index)
            ids.append(songId)
            if let stated = tracks[index].metadata?.title, !stated.isEmpty {
                titles[songId] = stated
            }
        }
        return (ids, titles)
    }

    /// Every outcome gets a sentence. Including "was already in
    /// there" and above all the limit, which is reported instead of truncating
    /// silently.
    static func text(for outcome: MaerPlaylists.AddOutcome, listName: String) -> String? {
        switch outcome {
        case .added:         return nil
        case .alreadyThere:  return String(localized: "Already in “\(listName)”.")
        case .limitReached(let limit):
            // The limit is not a private quota: playlists and podcast progress
            // share ONE iCloud budget, so the message must not suggest the
            // playlists had a compartment of their own.
            return String(localized: "Your playlists are full (\(limit) entries). They share the iCloud space with your podcast progress. Remove something first.")
        case .notQueueable:  return String(localized: "This cannot be added to a playlist.")
        case .showHasRule:   return String(localized: "“\(listName)” already has a rule for this show. Remove it first to choose another.")
        }
    }
}

// MARK: - Presentation host

/// The id of the hierarchy a playlist surface is shown in.
nonisolated enum PlaylistHostID {
    /// The app root. Everything that is not inside a modal.
    static let root = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
}

private struct PlaylistHostKey: EnvironmentKey {
    static let defaultValue = PlaylistHostID.root
}

extension EnvironmentValues {
    /// Which `playlistDialogs()` host the surrounding views belong to.
    var playlistHost: UUID {
        get { self[PlaylistHostKey.self] }
        set { self[PlaylistHostKey.self] = newValue }
    }
}

// MARK: - The one action

/// THE playlist action on every song, episode, book and catalogue row. It
/// only asks. The sheet decides which worlds are open to these entries.
struct AddToPlaylistButton: View {
    let itemId: String
    /// Several ids (an album, the queue). The same action with a set.
    var itemIds: [String]?
    /// What the calling surface has ON SCREEN for these ids.
    var knownTitles: [String: String] = [:]
    /// A surface that only learns its entry asynchronously (an album track
    /// row has to ask the server which song sits at that index) hands a
    /// resolver instead of ids. `itemId` then only serves the gate. Without
    /// this those rows would need their own copy of the action.
    var resolve: (() async -> (ids: [String], titles: [String: String]))?
    /// A routine's rule names itself (`RoutineWords`); every other entry is
    /// added to a playlist.
    var label: String?

    @Environment(\.playlistHost) private var host

    private var ids: [String] { itemIds ?? [itemId] }

    var body: some View {
        // Radio has no list entry. An endless stream is not one.
        if PlayQueue.canEnqueue(itemId) {
            Button {
                guard let resolve else {
                    PlaylistPresenter.shared.askToAdd(ids, titles: knownTitles, host: host)
                    return
                }
                Task {
                    let resolved = await resolve()
                    guard !resolved.ids.isEmpty else { return }
                    PlaylistPresenter.shared.askToAdd(resolved.ids, titles: resolved.titles,
                                                      host: host)
                }
            } label: {
                if let label {
                    Label(label, systemImage: "text.badge.plus")
                } else {
                    Label("Add to Playlist", systemImage: "text.badge.plus")
                }
            }
            .accessibilityIdentifier(label == nil ? "add-to-playlist" : "add-rule-\(itemId)")
        }
    }
}

extension View {
    /// One presentation host for the playlist surfaces. Belongs at the app
    /// root, and additionally at the root of every MODAL that carries playlist
    /// actions of its own. A sheet cannot be presented from underneath an
    /// open one, so each such hierarchy gets its own host and only the host a
    /// request came from presents it.
    func playlistDialogs(id: UUID = PlaylistHostID.root) -> some View {
        modifier(PlaylistDialogs(hostId: id))
    }
}

private struct PlaylistDialogs: ViewModifier {
    let hostId: UUID
    @ObservedObject private var presenter = PlaylistPresenter.shared

    /// nil for every host but the one that was asked. `sheet(item:)` then
    /// keeps quiet instead of racing the other host for the same request.
    private func mine<T>(_ value: T?) -> T? { presenter.host == hostId ? value : nil }

    func body(content: Content) -> some View {
        content
            .environment(\.playlistHost, hostId)
            .sheet(item: Binding(get: { mine(presenter.adding) },
                                 set: { if $0 == nil { presenter.adding = nil } })) {
                AddToPlaylistSheet(request: $0)
                    .followsAppearanceChoice()
            }
            .sheet(item: Binding(get: { mine(presenter.creating) },
                                 set: { if $0 == nil { presenter.creating = nil } })) { request in
                NavigationStack { PlaylistCreateForm(request: request) }
                    .softTopScrollEdge()
                    .followsAppearanceChoice()
            }
            // An alert presents fine from any level, so the message needs no
            // host. But it must be shown EXACTLY once.
            .alert("Playlist", isPresented: Binding(
                get: { presenter.message != nil && presenter.host == hostId },
                set: { if !$0 { presenter.message = nil } })) {
                Button("OK", role: .cancel) { presenter.message = nil }
            } message: {
                if let message = presenter.message { Text(verbatim: message) }
            }
            // Asked once after a rule went in; never switched on unasked.
            .alert("Download automatically?", isPresented: Binding(
                get: { presenter.offeringAutoDownload != nil && presenter.host == hostId },
                set: { if !$0 { presenter.offeringAutoDownload = nil } }),
                   presenting: presenter.offeringAutoDownload) { show in
                Button("Download Automatically") { PodcastAutoDownload.setEnabled(show.id, true) }
                Button("Not Now", role: .cancel) {}
            } message: { show in
                Text("Offline, a routine plays only downloaded episodes. Download new episodes of “\(show.title)” automatically?")
            }
    }
}

// MARK: - The one sheet

/// Pick a list. From BOTH worlds, in one leaf. The server section only
/// appears when a server exists AND owns every selected entry: a catalogue
/// track has no address there, so the section would be a dead target.
struct AddToPlaylistSheet: View {
    let request: PlaylistPresenter.AddRequest

    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var devicePlaylists = MaerPlaylists.shared
    @State private var serverPlaylists: [MusicPlaylist] = []
    @State private var loadingServer = true
    /// The server's lists could not be fetched: not "no playlists yet".
    @State private var serverFailed = false
    @State private var busy = false

    private var places: [PlaylistPlace] { PlaylistPresenter.places(for: request.ids) }
    /// The one server these entries may go to; with entries there is at
    /// most one (`PlaylistDestination.servers`).
    private var server: MusicSourceRule.Server? { PlaylistPresenter.servers(for: request.ids).first }
    private var showsServer: Bool { places.contains(.server) && server != nil }

    /// The server the sentences name: the entries' own, else the one active
    /// music server; with two and none of their own, none.
    private var namedServer: String? {
        let active = PlaylistPresenter.servers(for: [])
        let which = server ?? (active.count == 1 ? active.first : nil)
        let type = SubsonicProvider.configuredServerKey.flatMap { SubsonicClient.reportedType(server: $0) }
        return MusicSourceName.product(which, reportedType: type)
    }

    private var mixSentence: String {
        if let name = namedServer {
            return String(localized: "Mär playlists stay on your devices and can mix everything: music from \(name), open catalogs and local files.")
        }
        return String(localized: "Mär playlists stay on your devices and can mix everything: music from your music server, open catalogs and local files.")
    }

    private var onlyMaerSentence: String {
        PlaylistOnlyMaerSentence.text(namedServer: namedServer,
                                      anyMusicServer: !PlaylistPresenter.servers(for: []).isEmpty)
    }

    var body: some View {
        NavigationStack {
            List {
                if showsServer {
                    Section {
                        if loadingServer {
                            HStack { ProgressView(); Text("Loading…").foregroundStyle(.secondary) }
                        } else if serverFailed {
                            LoadFailedView(form: .row, sentence: "Playlists could not be loaded.") {
                                Task { await loadServer() }
                            }
                        } else if serverPlaylists.isEmpty {
                            Text("No playlists yet.").foregroundStyle(.secondary)
                        } else {
                            ForEach(serverPlaylists) { playlist in
                                row(title: playlist.name ?? String(localized: "Playlist"),
                                    count: playlist.songCount) {
                                    if await PlaylistPresenter.shared
                                        .addToServer(request.ids, playlistItemId: playlist.itemId) { dismiss() }
                                }
                            }
                        }
                        newListLink(place: .server)
                    } header: {
                        // With two servers the section says whose lists these are.
                        if let name = request.ids.first.flatMap(AppSession.shared.musicSourceLabel(forItemId:)) {
                            Text("Server playlists") + Text(verbatim: " · \(name)")
                        } else {
                            Text("Server playlists")
                        }
                    }
                }

                Section {
                    if devicePlaylists.playlists.isEmpty {
                        Text("No playlists yet.").foregroundStyle(.secondary)
                    } else {
                        ForEach(devicePlaylists.playlists) { list in
                            row(title: list.name, count: list.itemIds.count) {
                                await PlaylistPresenter.shared
                                    .addToDevice(request.ids, titles: request.titles,
                                                 listId: list.id, listName: list.name)
                                dismiss()
                            }
                        }
                    }
                    newListLink(place: .device)
                } header: {
                    Text("Mär playlists")
                } footer: {
                    // The explanation lands where the decision is made. And
                    // it says WHY the other world may be missing instead of
                    // leaving a silent gap.
                    Text(showsServer ? mixSentence
                         : PlaylistPresenter.mixesServers(request.ids)
                         ? String(localized: "Titles from two servers only fit into a playlist on your devices: a server playlist holds its own server's music only.")
                         : onlyMaerSentence)
                }
            }
            .navigationTitle("Add to Playlist")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .disabled(busy)
                        .accessibilityIdentifier("playlist-dialog-cancel")
                }
            }
            .overlay { if busy { ProgressView().controlSize(.large) } }
            .task { await loadServer() }
        }
        .softTopScrollEdge()
    }

    /// Creating from inside the sheet PUSHES. A second sheet on top of this
    /// one would not present.
    private func newListLink(place: PlaylistPlace) -> some View {
        NavigationLink {
            PlaylistCreateForm(request: .init(place: place, places: places,
                                              servers: server.map { [$0] } ?? [],
                                              ids: request.ids, titles: request.titles))
        } label: {
            Label("New Playlist", systemImage: "plus")
        }
        .disabled(busy)
    }

    private func row(title: String, count: Int?, action: @escaping () async -> Void) -> some View {
        Button {
            Task {
                busy = true
                await action()
                busy = false
            }
        } label: {
            HStack {
                Text(verbatim: title)
                Spacer()
                if let count { Text(verbatim: "\(count)").foregroundStyle(.secondary) }
            }
        }
        .disabled(busy)
    }

    private func loadServer() async {
        guard showsServer, let server else { loadingServer = false; return }
        // Only the target server's lists: with two servers the union would
        // offer the other's too, and adding there finds no songs.
        let provider = AppSession.shared.musicProvider(serving: .one(server))
        switch await FetchAnswer.of("server playlists", logger: .music, { try await provider.allPlaylists() }) {
        case .value(let all):
            serverPlaylists = PlaylistPresentation.realPlaylists(all)
            serverFailed = false
        case .failed:
            serverFailed = serverPlaylists.isEmpty
        case .cancelled:
            break
        }
        loadingServer = false
    }
}

// MARK: - The one create dialog

/// Name plus the place. With one explaining line per place, because the
/// difference between the worlds is real and only matters at this moment.
/// Used pushed (from the sheet) and presented (from the row cards).
struct PlaylistCreateForm: View {
    let request: PlaylistPresenter.CreateRequest

    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var place: PlaylistPlace = .device
    @State private var server: MusicSourceRule.Server?
    @State private var busy = false
    @FocusState private var nameFocused: Bool

    /// One row per place, and with several servers one server row each:
    /// "Where?" names the server by the name it reports.
    private struct Option: Identifiable {
        let place: PlaylistPlace
        let server: MusicSourceRule.Server?
        /// Stable handles: one server keeps the handle of before.
        let id: String
    }

    private var options: [Option] {
        request.places.flatMap { option -> [Option] in
            guard option == .server, request.servers.count > 1 else {
                return [Option(place: option, server: option == .server ? request.servers.first : nil,
                               id: option.rawValue)]
            }
            return request.servers.map { Option(place: .server, server: $0, id: "server-\($0)") }
        }
    }

    private static func serverName(_ server: MusicSourceRule.Server) -> String {
        let music = AppSession.shared.musicProvider(serving: .one(server))
        return music.sourceNames[music.providerId] ?? music.providerId
    }

    var body: some View {
        Form {
            Section {
                TextField("Name", text: $name)
                    .focused($nameFocused)
                    .accessibilityIdentifier("new-playlist-name")
            }
            // One place = no choice to make; the single explanation still
            // stands, as the footer of the name section.
            if request.places.count > 1 {
                Section {
                    ForEach(options) { option in
                        Button {
                            place = option.place
                            server = option.server
                        } label: {
                            HStack(alignment: .firstTextBaseline) {
                                VStack(alignment: .leading, spacing: 2) {
                                    if request.servers.count > 1, let named = option.server {
                                        Text(Self.title(option.place)).foregroundStyle(.primary)
                                            + Text(verbatim: " · \(Self.serverName(named))").foregroundStyle(.secondary)
                                    } else {
                                        Text(Self.title(option.place)).foregroundStyle(.primary)
                                    }
                                    Text(Self.explanation(option.place))
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                if place == option.place, server == option.server {
                                    Image(systemName: "checkmark").foregroundStyle(AppTheme.accent)
                                }
                            }
                        }
                        .accessibilityIdentifier("new-playlist-place-\(option.id)")
                    }
                } header: {
                    Text("Where")
                }
            } else if let only = request.places.first {
                Section { Text(Self.explanation(only)).font(.caption).foregroundStyle(.secondary) }
            }
        }
        .navigationTitle("New Playlist")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
                    .disabled(busy)
                    .accessibilityIdentifier("playlist-dialog-cancel")
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Create") {
                    Task {
                        busy = true
                        let done = await PlaylistPresenter.shared
                            .create(name: name, place: place, server: server,
                                    ids: request.ids, titles: request.titles)
                        busy = false
                        if done { dismiss() }
                    }
                }
                .disabled(busy)
                .accessibilityIdentifier("new-playlist-create")
            }
        }
        .onAppear {
            place = request.place
            server = request.servers.first
            nameFocused = true
        }
        .task { await preselectLastChangedServer() }
    }

    /// With several servers to choose from, the one whose playlist changed
    /// last is preselected; unknown moments keep the first.
    private func preselectLastChangedServer() async {
        guard request.servers.count > 1, request.place == .server else { return }
        var stamped: [(server: MusicSourceRule.Server, changedAt: Double?)] = []
        for candidate in request.servers {
            let lists = (try? await AppSession.shared.musicProvider(serving: .one(candidate)).allPlaylists()) ?? []
            stamped += lists.map { (candidate, $0.changedAt) }
        }
        if place == .server, let latest = PlaylistDestination.lastChanged(stamped) { server = latest }
    }

    /// The two worlds by name: a server playlist, and a Mär playlist. Not
    /// "local": a Mär playlist travels between the devices.
    static func title(_ place: PlaylistPlace) -> LocalizedStringKey {
        switch place {
        case .server: return "Server playlist"
        case .device: return "Mär playlist"
        }
    }

    static func explanation(_ place: PlaylistPlace) -> LocalizedStringKey {
        switch place {
        case .server:
            return "Holds your server's music only, and every client of that server sees it."
        case .device:
            return "Mixes everything (server music, open catalogs and local files) and travels between your devices via iCloud. Another client of your server does not see it."
        }
    }
}
