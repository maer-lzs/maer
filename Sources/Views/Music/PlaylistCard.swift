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
    /// Mosaic covers and the most frequent artists, fetched together because
    /// they come from the same source.
    let mosaic: () async -> (covers: [URL], artists: [String])
    /// nil = this world cannot rename/delete here; the menu entry then stays
    /// away instead of offering something that fails (G8).
    let rename: ((String) async -> Void)?
    let delete: (() async -> Void)?
    /// The capsule on the card's cover naming where the list lives. Only
    /// the device lists carry one (the minority in the one mixed row);
    /// server lists carry none.
    var placeCapsule: String? = nil
    /// What the mosaic task keys on: the device list's snapshots heal in
    /// the background, so the mosaic re-runs when they land.
    var mosaicKey: String = ""
}

struct PlaylistCard: View {
    let source: PlaylistCardSource
    @ObservedObject var playerCoordinator: PlayerCoordinator
    @State private var showRename = false
    @State private var renameText = ""
    @State private var showDeleteConfirm = false
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
                PlaylistArtwork(playlistID: source.id, coverURLs: coverURLs, cornerRadius: 0)
                    .overlay(alignment: .bottom) {
                        LinearGradient(colors: [.clear, tint],
                                       startPoint: .top, endPoint: .bottom)
                            .frame(height: CardMetrics.featuredCardWidth * 0.3)
                    }
                    .overlay(alignment: .topLeading) { placeCapsule }
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
            CardCornerButton(systemImage: "shuffle",
                             accessibilityLabel: Text("Shuffle"),
                             accessibilityId: "playlist-shuffle-badge") {
                Task { await playerCoordinator.shufflePlay(items: await source.shufflePool(),
                                                          contextSource: source.title) }
            }
            .padding(12)
        }
        .dynamicTypeSize(...DynamicTypeSize.accessibility1)
        .task(id: coverURLs.first) { await colorLoader.load(from: coverURLs.first) }
        .contextMenu {
            ShufflePlayButton(playerCoordinator: playerCoordinator,
                              style: .menuItem, pool: source.shufflePool)
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
                Task { await source.rename?(name) }
            }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog("Delete this playlist?", isPresented: $showDeleteConfirm,
                            titleVisibility: .visible) {
            Button("Delete Playlist", role: .destructive) {
                Task { await source.delete?() }
            }
        }
        .task(id: source.id + source.mosaicKey) {
            let loaded = await source.mosaic()
            coverURLs = loaded.covers
            artistNames = loaded.artists
        }
    }

    /// The place capsule on the cover, in the licence capsule's look.
    @ViewBuilder
    private var placeCapsule: some View {
        if let text = source.placeCapsule {
            Text(text)
                .font(.caption2.weight(.medium))
                .lineLimit(1)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(.black.opacity(0.55), in: Capsule())
                .foregroundStyle(.white)
                .padding(8)
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
    static func server(_ playlist: MusicPlaylist) -> PlaylistCardSource {
        let music = AppSession.shared.musicProvider
        let itemId = music.itemId(playlistId: playlist.id)
        return PlaylistCardSource(
            id: itemId,
            title: playlist.name ?? String(localized: "Playlist"),
            changedAtMs: playlist.changedAt,
            songCount: playlist.songCount ?? 0,
            durationSeconds: Int(playlist.duration ?? 0),
            detailRoute: .album(playlistLibraryItem(playlist)),
            open: { coordinator in await coordinator.open(item: playlistLibraryItem(playlist)) },
            shufflePool: { await music.songItems(forItemId: itemId) },
            mosaic: {
                let ids = await music.playlistMosaicCoverIDs(forItemId: itemId)
                let artists = PlaylistPresentation.topArtists(
                    await music.playlistArtistNames(forItemId: itemId))
                return (ids.compactMap { music.coverURL(coverArtId: $0) }, artists)
            },
            rename: { newName in
                try? await music.renamePlaylist(itemId: itemId, newName: newName)
                music.librarySynced.send()
            },
            delete: {
                try? await music.deletePlaylist(itemId: itemId)
                music.librarySynced.send()
            })
    }

    /// The DEVICE world's factory. The second world the card was split for.
    /// A Mär list stores IDS, so everything the card shows is resolved here
    /// and nowhere else: covers and artists come from whatever this device can
    /// answer, entries it cannot resolve simply contribute nothing to the
    /// mosaic (resolvability is a property of the device, never of the entry).
    @MainActor
    static func device(_ list: MaerPlaylists.Playlist) -> PlaylistCardSource {
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
            open: { coordinator in await coordinator.playInOrder(items: items(of: list),
                                                                 contextSource: list.name) },
            shufflePool: { items(of: list) },
            mosaic: {
                // A list from before the snapshots existed has none to draw
                // from: fill them now, on the device that can resolve the
                // entries (saves only when something was learned).
                store.backfillTitles(playlistId: list.id)
                // A cover this device cannot derive comes from the entry's
                // snapshot (a public catalogue address that travelled).
                let covers = list.itemIds
                    .compactMap { id in
                        AppSession.shared.coverURL(forItemId: id)
                            ?? list.carried(for: id)?.coverURL.flatMap(URL.init(string:))
                    }
                    .reduce(into: [URL]()) { out, url in if !out.contains(url) { out.append(url) } }
                let artists = PlaylistPresentation.topArtists(
                    list.itemIds.compactMap { list.carried(for: $0)?.subtitle }
                    + items(of: list).compactMap(\.author))
                return (Array(covers.prefix(4)), artists)
            },
            rename: { newName in store.rename(playlistId: list.id, to: newName) },
            delete: { store.delete(playlistId: list.id) },
            placeCapsule: String(localized: "On your devices"),
            mosaicKey: "\(list.snapshots.count)")
    }

    /// What this device can actually play of the list, in list order: the
    /// seam's answer per entry, with the entry's snapshot.
    @MainActor
    private static func items(of list: MaerPlaylists.Playlist) -> [LibraryItem] {
        list.itemIds.compactMap { MaerPlaylists.shared.resolution(of: $0, in: list).item }
    }
}
