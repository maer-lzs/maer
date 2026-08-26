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
        /// What may be chosen. One place means no choice is shown (G8).
        var places: [PlaylistPlace]
        var ids: [String] = []
        var titles: [String: String] = [:]
        let id = UUID()
    }

    @Published var adding: AddRequest?
    @Published var creating: CreateRequest?
    @Published var message: String?

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
                                 places: places, ids: ids, titles: titles)
    }

    /// Which worlds these entries may go to. With nothing selected (creating
    /// an empty list) both stand, as far as a server exists at all.
    static func places(for ids: [String]) -> [PlaylistPlace] {
        let music = AppSession.shared.musicProvider
        return PlaylistDestination.places(
            serverConfigured: AppStorageKeys.musicServerActive,
            allOwnedByServer: ids.allSatisfy { music.owns(itemId: $0) })
    }

    // MARK: - Doing it

    func addToDevice(_ ids: [String], titles: [String: String],
                     listId: String, listName: String) async {
        let expanded = await Self.expandedForDevice(ids, titles: titles)
        message = Self.text(for: MaerPlaylists.shared.add(itemIds: expanded.ids,
                                                          to: listId,
                                                          knownTitles: expanded.titles),
                            listName: listName)
    }

    /// The server states which songs an item contributes. An album expands
    /// there exactly as it does here.
    func addToServer(_ ids: [String], playlistItemId: String) async -> Bool {
        let music = AppSession.shared.musicProvider
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
            Logger.library.error("PLAYLIST server add failed: \(error.localizedDescription, privacy: .public)")
            message = String(localized: "Could not add to the playlist.")
            return false
        }
    }

    /// Create in the chosen world and put the carried entries in. Returns
    /// false when the server refused. The caller then keeps the form open.
    func create(name rawName: String, place: PlaylistPlace,
                ids: [String], titles: [String: String]) async -> Bool {
        let trimmed = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = trimmed.isEmpty ? String(localized: "Playlist") : trimmed
        switch place {
        case .device:
            let list = MaerPlaylists.shared.create(name: name)
            if !ids.isEmpty {
                await addToDevice(ids, titles: titles, listId: list.id, listName: name)
            }
            return true
        case .server:
            let music = AppSession.shared.musicProvider
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
        let music = AppSession.shared.musicProvider
        var out: [String] = []
        var titles = carried
        for id in ids {
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
    private static func expandedCatalogRelease(_ id: String) async -> (ids: [String], titles: [String: String]) {
        let provider = FreeCatalogProvider.shared
        var form = provider.archiveForm(itemId: id)
        if form == nil {
            // The form is only known once the detail was seen. Ask for it
            // rather than guessing from the id.
            _ = try? await provider.fetchItemDetail(itemId: id)
            form = provider.archiveForm(itemId: id)
        }
        guard form == .album,
              let detail = try? await provider.fetchItemDetail(itemId: id),
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
            return String(localized: "Your playlists are full (\(limit) entries) — they share the iCloud space with your podcast progress. Remove something first.")
        case .notQueueable:  return String(localized: "This cannot be added to a playlist.")
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
                Label("Add to Playlist", systemImage: "text.badge.plus")
            }
            .accessibilityIdentifier("add-to-playlist")
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
            }
            .sheet(item: Binding(get: { mine(presenter.creating) },
                                 set: { if $0 == nil { presenter.creating = nil } })) { request in
                NavigationStack { PlaylistCreateForm(request: request) }
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
    }
}

// MARK: - The one sheet

/// Pick a list. From BOTH worlds, in one leaf. The server section only
/// appears when a server exists AND owns every selected entry: a catalogue
/// track has no address there, so the section would be a dead target (G8).
struct AddToPlaylistSheet: View {
    let request: PlaylistPresenter.AddRequest

    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var devicePlaylists = MaerPlaylists.shared
    @State private var serverPlaylists: [MusicPlaylist] = []
    @State private var loadingServer = true
    @State private var busy = false

    private var places: [PlaylistPlace] { PlaylistPresenter.places(for: request.ids) }
    private var showsServer: Bool { places.contains(.server) }

    var body: some View {
        NavigationStack {
            List {
                if showsServer {
                    Section("On your server") {
                        if loadingServer {
                            HStack { ProgressView(); Text("Loading…").foregroundStyle(.secondary) }
                        } else if serverPlaylists.isEmpty {
                            Text("No playlists yet.").foregroundStyle(.secondary)
                        } else {
                            ForEach(serverPlaylists) { playlist in
                                row(title: playlist.name ?? String(localized: "Playlist"),
                                    count: playlist.songCount) {
                                    let itemId = AppSession.shared.musicProvider.itemId(playlistId: playlist.id)
                                    if await PlaylistPresenter.shared
                                        .addToServer(request.ids, playlistItemId: itemId) { dismiss() }
                                }
                            }
                        }
                        newListLink(place: .server)
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
                    Text("On your devices")
                } footer: {
                    // The explanation lands where the decision is made. And
                    // it says WHY the other world may be missing instead of
                    // leaving a silent gap.
                    Text(showsServer
                         ? String(localized: "Device playlists stay on your devices and can mix everything — your server's music, free catalogs and local files.")
                         : String(localized: "These entries can only go into a device playlist: a music server cannot reference a catalog or local address."))
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
    }

    /// Creating from inside the sheet PUSHES. A second sheet on top of this
    /// one would not present.
    private func newListLink(place: PlaylistPlace) -> some View {
        NavigationLink {
            PlaylistCreateForm(request: .init(place: place, places: places,
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
        guard showsServer else { loadingServer = false; return }
        let all = (try? await AppSession.shared.musicProvider.allPlaylists()) ?? []
        serverPlaylists = PlaylistPresentation.realPlaylists(all)
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
    @State private var busy = false
    @FocusState private var nameFocused: Bool

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
                    ForEach(request.places) { option in
                        Button { place = option } label: {
                            HStack(alignment: .firstTextBaseline) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(Self.title(option)).foregroundStyle(.primary)
                                    Text(Self.explanation(option))
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                if place == option {
                                    Image(systemName: "checkmark").foregroundStyle(AppTheme.accent)
                                }
                            }
                        }
                        .accessibilityIdentifier("new-playlist-place-\(option.rawValue)")
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
                            .create(name: name, place: place,
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
            nameFocused = true
        }
    }

    static func title(_ place: PlaylistPlace) -> LocalizedStringKey {
        switch place {
        case .server: return "On your server"
        case .device: return "On your devices"
        }
    }

    static func explanation(_ place: PlaylistPlace) -> LocalizedStringKey {
        switch place {
        case .server:
            return "Holds your server's music only, and every client of that server sees it."
        case .device:
            return "Mixes everything — server music, free catalogs and local files — and travels between your devices via iCloud."
        }
    }
}
