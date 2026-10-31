// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import SwiftUI
import Combine

/// THE playlist card. It lived `private` inside `MusicView`
/// and was welded to `MusicPlaylist`. Which is why the device playlists could
/// not have it, and why building them a second card was the thing worth
/// waiting for (the mosaic, the artist line, the colour derivation and the
/// height parity with the Featured cards are the card, not decoration).
///
/// The split is deliberate: everything server-specific is a VALUE or a
/// CLOSURE in `PlaylistCardSource`, the card itself knows neither provider nor
/// namespace. A second world plugs in by writing one factory, not one card.
struct PlaylistCardSource: Identifiable {
    /// Stable id for the deterministic tint and for `task(id:)`.
    let id: String
    let title: String
    /// ms since 1970. The caption line ("changed 3 days ago"). Epoch, never
    /// a formatted string: zones exist in the display only.
    let changedAtMs: Double?
    let songCount: Int
    /// nil = this world cannot state a running time without resolving every
    /// entry first; the meta line then carries the count alone instead of a
    /// zero that would read as "empty".
    let durationSeconds: Int?
    /// Where the detail pill leads.
    let detailRoute: MusicRoute
    /// Tap on the card body. Plays in normal order. Takes the coordinator
    /// the card was handed instead of reaching for a global one: the card is
    /// injected, and a factory must not quietly widen that.
    let open: (PlayerCoordinator) async -> Void
    /// The songs, for the shared shuffle path.
    let shufflePool: () async -> [LibraryItem]
    /// The same songs as a shuffle's pool, with why it is empty when it is.
    let shuffleDraw: () async -> ShufflePool
    /// Mosaic covers and the most frequent artists, fetched together because
    /// they come from the same source.
    let mosaic: () async -> (covers: [URL], artists: [String])
    /// The mosaic covers where the world states them, asked as the card
    /// draws: a device list's, from the same question its page asks
    /// (`deviceCovers`), so they follow whatever this device can answer at
    /// each render, also after `mosaic` taught the sources new covers.
    /// nil = the covers come from `mosaic`.
    var covers: (@MainActor () -> [URL])? = nil
    /// nil = this world cannot rename/delete here; the menu entry then stays
    /// away instead of offering something that fails. A server that does
    /// not take the change throws, and the card says so.
    let rename: ((String) async throws -> Void)?
    let delete: (() async throws -> Void)?
    /// The capsule on the card's cover naming where the list lives: "Mär"
    /// on a device list; the server's name on a server list while two music
    /// servers are active; nothing on a server list otherwise.
    var placeCapsule: String? = nil
    /// Which world the list belongs to. The card's name hangs on this, not
    /// on the capsule, now that server lists can carry one too.
    var isDeviceList = false
    /// What the mosaic task keys on: the device list's snapshots heal in
    /// the background, so the mosaic re-runs when they land.
    var mosaicKey: String = ""
    /// What must be on the device for the list to play offline: a server
    /// list's own id (it downloads as one), a Mär list's entries.
    var downloadIds: [String] = []
}

struct PlaylistCard: View {
    let source: PlaylistCardSource
    @ObservedObject var playerCoordinator: PlayerCoordinator
    @Environment(\.pushMusicRoute) private var pushMusicRoute
    @State private var showRename = false
    @State private var renameText = ""
    @State private var showDeleteConfirm = false
    @State private var actionFailed = false
    @State private var coverURLs: [URL] = []
    /// The playlist's most frequent artists as ONE truncating line
    /// (empty = no data → blank, height reserved so the card never jiggles).
    @State private var artistNames: [String] = []
    /// The mixed card color comes from the BOTTOM (big) mosaic
    /// cover. It borders the text block (color continuity).
    @StateObject private var colorLoader = CoverColorLoader()
    // EXACT height parity with the Featured-card anatomy.
    @ScaledMetric(relativeTo: .subheadline) private var pillReserve: CGFloat = 40
    @ScaledMetric(relativeTo: .headline) private var titleMinHeight: CGFloat = 44
    @ScaledMetric(relativeTo: .subheadline) private var metaMinHeight: CGFloat = 20

    /// The card's own name. It lives here because the card knows which
    /// world it belongs to; the row above must not name it from outside,
    /// or the name lands on the container again.
    nonisolated static func identifier(for source: PlaylistCardSource) -> String {
        source.isDeviceList ? "maer-playlist-\(source.id)" : "server-playlist-\(source.id)"
    }

    /// The rule is pure and lives with the other card rules; the card only
    /// renders it.
    private var offersShuffle: Bool {
        PlaylistPresentation.offersShuffle(trackCount: source.songCount)
    }

    /// The covers the mosaic draws: the source's own where it states them,
    /// else what `mosaic` loaded.
    private var shownCovers: [URL] {
        source.covers?() ?? coverURLs
    }

    /// Deterministic per-id tint as the instant fallback; the extracted
    /// bottom-cover color takes over once loaded.
    private var tint: Color {
        colorLoader.hasAccent ? colorLoader.accent : PlaylistArtwork.color(for: source.id)
    }

    var body: some View {
        // The SAME card format as BookFeaturedCard / PodcastFeaturedCard
        // (featuredCardWidth, cover face on top, text block on the card color
        // below, radius 20). Mosaic as the cover. The card TAP PLAYS in
        // normal order (pill left = detail, corner right = shuffle).
        Button {
            Task { await source.open(playerCoordinator) }
        } label: {
            VStack(alignment: .leading, spacing: 0) {
                // The ONE observing leaf, like every tile: offline disc and
                // dim when nothing of the list is here, the downloaded mark
                // when all of it is, both in the one stack at the top right.
                MediaAvailabilityScope(itemId: source.id, anyOf: source.downloadIds) { unavailable, allHere in
                    PlaylistArtwork(playlistID: source.id, coverURLs: shownCovers, cornerRadius: 0)
                        .overlay(alignment: .bottom) {
                            LinearGradient(colors: [.clear, tint],
                                           startPoint: .top, endPoint: .bottom)
                                .frame(height: CardMetrics.featuredCardWidth * 0.3)
                        }
                        .opacity(unavailable ? 0.5 : 1)
                        .overlay(alignment: .topTrailing) {
                            StandardCoverMarks(availability: CoverAvailability.of(failed: false, downloaded: allHere,
                                                                                  unavailable: unavailable),
                                               coverSide: nil)
                                .padding(3)
                        }
                        .overlay(alignment: .topLeading) { placeCapsule }
                }
                VStack(alignment: .leading, spacing: 5) {
                    Text(changedText ?? " ")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.85))
                        .lineLimit(1)
                    Text(source.title)
                        .font(.headline)
                        .foregroundStyle(.white)
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, minHeight: titleMinHeight, alignment: .topLeading)
                    Text(metaLine)
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.85))
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, minHeight: metaMinHeight, alignment: .topLeading)
                    Text(artistNames.isEmpty ? " " : artistNames.joined(separator: ", "))
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.7))
                        .lineLimit(1)
                }
                .padding(14)
                .padding(.bottom, pillReserve)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // The card's own name sits HERE, on the button it means, not
        // on the whole card. On the container SwiftUI folds the subtree
        // into one element, so the details pill and the shuffle corner
        // reported the card's name instead of their own: three controls,
        // one name. VoiceOver announced the same thing three times and
        // could not tell the corners apart.
        .accessibilityIdentifier(Self.identifier(for: source))
        .frame(width: CardMetrics.featuredCardWidth)
        .background(tint)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .animation(.easeInOut(duration: 0.45), value: colorLoader.hasAccent)
        // The SAME two card controls as the Featured cards, at the
        // SAME positions. Details pill bottom-left, corner button bottom-right.
        .overlay(alignment: .bottomLeading) {
            CardDetailPill(value: source.detailRoute).padding(12)
        }
        .overlay(alignment: .bottomTrailing) {
            // A list with no tracks has nothing to shuffle. The corner used
            // to stand there and answer a tap with nothing at all: the
            // control was offered, the action could not act, and there was
            // no way to tell the two apart. The detail pill stays, because
            // that is the way INTO an empty list.
            if offersShuffle {
                CardCornerButton(systemImage: "shuffle",
                                 accessibilityLabel: Text("Shuffle"),
                                 accessibilityId: "playlist-shuffle-badge") {
                    Task { await playerCoordinator.shufflePlay(items: await source.shufflePool(),
                                                              contextSource: source.title) }
                }
                .padding(12)
            }
        }
        .dynamicTypeSize(...DynamicTypeSize.accessibility1)
        .task(id: shownCovers.first) { await colorLoader.load(from: shownCovers.first) }
        .contextMenu {
            // The entries every album and playlist tile offers; the queue
            // and the playlist take the list's songs. A list without a
            // track offers nothing to play, the same gate as the corner.
            CollectionMenuItems(
                playerCoordinator: playerCoordinator, itemId: source.id,
                isPlayable: offersShuffle,
                play: { await source.open(playerCoordinator) },
                queueIds: { await source.shufflePool().map(\.id) },
                songs: source.shuffleDraw,
                addEntries: {
                    let songs = await source.shufflePool()
                    return (songs.map(\.id), Dictionary(songs.map { ($0.id, $0.title) }, uniquingKeysWith: { first, _ in first }))
                },
                details: { pushMusicRoute(source.detailRoute) })
            // A server playlist downloads as one, like an album.
            // A Mär list holds single songs and has no download of its own.
            if !source.isDeviceList {
                MusicDownloadMenuItems(itemId: source.id)
            }
            if source.rename != nil {
                Button {
                    renameText = source.title
                    showRename = true
                } label: { Label("Rename Playlist", systemImage: "pencil") }
            }
            if source.delete != nil {
                Button(role: .destructive) { showDeleteConfirm = true } label: {
                    Label("Delete Playlist", systemImage: "trash")
                }
            }
        }
        .alert("Rename Playlist", isPresented: $showRename) {
            TextField("Name", text: $renameText)
            Button("Rename") {
                let name = renameText
                Task {
                    guard let rename = source.rename else { return }
                    let done = await FetchAnswer.of("playlist rename", logger: .music) { try await rename(name) }
                    if done.failed { actionFailed = true }
                }
            }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog("Delete this playlist?", isPresented: $showDeleteConfirm,
                            titleVisibility: .visible) {
            Button("Delete Playlist", role: .destructive) {
                Task {
                    guard let delete = source.delete else { return }
                    let done = await FetchAnswer.of("playlist delete", logger: .music) { try await delete() }
                    if done.failed { actionFailed = true }
                }
            }
        }
        .actionFailedAlert($actionFailed)
        .task(id: source.id + source.mosaicKey) {
            let loaded = await source.mosaic()
            coverURLs = loaded.covers
            artistNames = loaded.artists
        }
    }

    /// The place capsule on the cover: the one cover capsule.
    @ViewBuilder
    private var placeCapsule: some View {
        if let text = source.placeCapsule {
            CoverCapsule(text: text, inset: 8)
        }
    }

    /// Caption line: when the playlist last changed (the row sorts by this).
    private var changedText: String? {
        guard let ms = source.changedAtMs else { return nil }
        return Date(timeIntervalSince1970: ms / 1000).formatted(.relative(presentation: .named))
    }

    private var metaLine: String {
        // "tracks" (lowercase) is NOT a casing duplicate of "Tracks".
        // This one sits INSIDE a sentence ("18 tracks · 1:12").
        let count = "\(source.songCount) \(String(localized: "tracks"))"
        guard let seconds = source.durationSeconds else { return count }
        return "\(count) · \(PlaylistPresentation.durationText(seconds: seconds))"
    }
}

extension PlaylistCardSource {
    /// The SERVER world's factory. Everything provider-bound lives here, so
    /// the card above stays free of it.
    @MainActor
    static func server(_ playlist: MusicPlaylist, sourceLabel: String? = nil) -> PlaylistCardSource {
        // The playlist's own server answers every question about it.
        let itemId = playlist.itemId
        let music = AppSession.shared.musicProvider(for: itemId)
        return PlaylistCardSource(
            id: itemId,
            title: playlist.name ?? String(localized: "Playlist"),
            changedAtMs: playlist.changedAt,
            songCount: playlist.songCount ?? 0,
            durationSeconds: PlaylistPresentation.knownSeconds(playlist.duration),
            detailRoute: .album(playlistLibraryItem(playlist)),
            open: { coordinator in await coordinator.open(item: playlistLibraryItem(playlist)) },
            shufflePool: { await music.songItems(forItemId: itemId) },
            shuffleDraw: { await CollectionSongs.serverPool(itemId) },
            mosaic: {
                let ids = await music.playlistMosaicCoverIDs(forItemId: itemId)
                let artists = PlaylistPresentation.topArtists(
                    await music.playlistArtistNames(forItemId: itemId))
                return (ids.compactMap { music.coverURL(coverArtId: $0) }, artists)
            },
            // Server truth either way: the row re-reads the list after a
            // change and after a refusal.
            rename: { newName in
                defer { music.librarySynced.send() }
                try await music.renamePlaylist(itemId: itemId, newName: newName)
            },
            delete: {
                defer { music.librarySynced.send() }
                try await music.deletePlaylist(itemId: itemId)
            },
            // Its server's name while two music servers are active; the
            // row asks its router and hands it in.
            placeCapsule: sourceLabel,
            downloadIds: [itemId])
    }

    /// The DEVICE world's factory. The second world the card was split for.
    /// A Mär list stores IDS, so everything the card shows is resolved here
    /// and nowhere else: covers and artists come from whatever this device can
    /// answer, entries it cannot resolve simply contribute nothing to the
    /// mosaic (resolvability is a property of the device, never of the entry).
    /// The covers are asked of `router`, the one door for id questions.
    @MainActor
    static func device(_ list: MaerPlaylists.Playlist, router: ItemRouter = .live) -> PlaylistCardSource {
        let store = MaerPlaylists.shared
        return PlaylistCardSource(
            id: list.id,
            title: list.name,
            // The store keeps seconds; the card speaks milliseconds.
            changedAtMs: list.updatedAt * 1000,
            songCount: list.itemIds.count,
            // A running time would mean resolving every entry across every
            // provider. The count stands alone instead of guessing.
            durationSeconds: nil,
            detailRoute: .maerPlaylist(list.id),
            open: { coordinator in await RoutinePlayback.start(list, in: store, on: coordinator) },
            shufflePool: { items(of: list, in: store) },
            shuffleDraw: { .of(items(of: list, in: store)) },
            mosaic: {
                // A list from before the snapshots existed has none to draw
                // from: fill them now, on the device that can resolve the
                // entries (saves only when something was learned).
                store.backfillTitles(playlistId: list.id)
                let artists = PlaylistPresentation.topArtists(
                    list.itemIds.compactMap { list.carried(for: $0)?.subtitle }
                    + items(of: list, in: store).compactMap(\.author))
                // An entry whose source has not named its cover yet (a music
                // server song met nowhere else) is asked here; the covers
                // this returns change the card's state, so it draws
                // `covers` again with what was learned.
                _ = await router.learnCovers(list.itemIds)
                return (deviceCovers(list, router: router), artists)
            },
            // Asked as the card draws, like the list's page asks it: a card
            // first drawn before its music server answers draws the covers
            // once the server does.
            covers: { deviceCovers(list, router: router) },
            rename: { newName in store.rename(playlistId: list.id, to: newName) },
            delete: { store.delete(playlistId: list.id) },
            // The capsule names the world, not a place: these lists travel
            // between the devices, so "on your devices" said the wrong
            // thing. Only Mär's own lists carry it; a server list wears
            // nothing (decided 06.09.2026).
            placeCapsule: String(localized: "Mär"),
            isDeviceList: true,
            mosaicKey: "\(list.snapshots.count)",
            downloadIds: list.itemIds)
    }

    /// The covers of a device list's mosaic, in list order and each once,
    /// for the card and the list's page. A cover this device cannot derive
    /// comes from the entry's snapshot (a public catalogue address that
    /// travelled).
    @MainActor
    static func deviceCovers(_ list: MaerPlaylists.Playlist, router: ItemRouter = .live) -> [URL] {
        list.itemIds
            .compactMap { deviceCover(of: $0, in: list, router: router) }
            .reduce(into: [URL]()) { out, url in if !out.contains(url) { out.append(url) } }
    }

    /// One entry's cover on a device playlist: its source's, else the
    /// public address its snapshot carries. The mosaic and the row ask this.
    @MainActor
    static func deviceCover(of id: String, in list: MaerPlaylists.Playlist, router: ItemRouter = .live) -> URL? {
        router.coverURL(id) ?? list.carried(for: id)?.coverURL.flatMap(URL.init(string:))
    }

    /// What this device can actually play of the list, in list order: the
    /// seam's answer per entry, with the entry's snapshot, and a rule's
    /// episodes from what the device holds (`RoutinePlayback.held`). The
    /// store is the factory's; the helper takes it rather than reaching for it.
    @MainActor
    static func items(of list: MaerPlaylists.Playlist, in store: MaerPlaylists) -> [LibraryItem] {
        RoutinePlayback.held(list, in: store).items
    }
}
