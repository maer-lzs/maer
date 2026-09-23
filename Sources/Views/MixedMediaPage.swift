// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import SwiftUI

/// The full list behind a capped Home row.
///
/// Home's rows are deliberately CROSS-MEDIA (books + episodes + music, merged
/// by recency), so their page cannot be one of the book surfaces. It would
/// silently drop the episodes and albums the row shows. Hence one page that
/// renders exactly the row's own cards, carrying the ids it previews.
nonisolated enum MixedRowRoute: Hashable {
    case continueListening
    case recentlyAdded
    /// The Rediscover pool page.
    case rediscoverPool
    /// The mixed "listen again" row, unabridged. The sources carry
    /// more than the row shows (radio MRU + album progress).
    case listenAgain

    /// Same wording as the row. The page IS that row, unabridged.
    var title: String {
        switch self {
        case .continueListening: String(localized: "Keep Listening")
        case .recentlyAdded:     String(localized: "Recently Added")
        case .rediscoverPool:    String(localized: "Rediscover")
        case .listenAgain:       String(localized: "Listen Again")
        }
    }
}

/// A Home continue card: book, music (playlist/album) or podcast episode,
/// resolved from a bare id. Shared by the row and its full page so
/// the two can never render different cards for the same entry.
struct HomeContinueCard: View {
    @Environment(\.itemRouter) private var router
    let id: String
    /// Package 3: the playlist/album progress bar; nil degrades to a plain
    /// cover card, which is also what an unfetched progress map yields.
    let musicProgress: BookProgress?
    let playerCoordinator: PlayerCoordinator
    let libraryViewModel: LibraryViewModel

    var body: some View {
        if let entry = libraryViewModel.entry(id: id) {
            BookFeaturedCard(entry: entry,
                             playerCoordinator: playerCoordinator,
                             libraryViewModel: libraryViewModel)
        } else if AppSession.shared.musicProvider(for: id).owns(itemId: id),
                  [.playlist, .album].contains(AppSession.shared.musicProvider(for: id).kind(of: id)),
                  let item = router.item(id) {
            // Package 3 + M1: playlists AND albums resume here (mosaic for
            // playlists, the album cover for albums. The card degrades to a
            // single-cover fill on its own).
            MusicContinueCard(item: item,
                              progress: musicProgress,
                              playerCoordinator: playerCoordinator)
        } else if let item = router.item(id) {
            PodcastFeaturedCard(item: item, playerCoordinator: playerCoordinator)
        }
    }
}

/// A "Recently Added" tile: the book cell for library books, the album cell for
/// everything else. Shared by the row and its full page.
struct HomeRecentlyAddedTile: View {
    let item: LibraryItem
    let playerCoordinator: PlayerCoordinator
    let libraryViewModel: LibraryViewModel

    var body: some View {
        if let entry = libraryViewModel.entry(id: item.id) {
            BookGridCell(entry: entry, width: 150,
                         playerCoordinator: playerCoordinator, libraryViewModel: libraryViewModel)
        } else {
            AlbumCell(item: item, width: 150, playerCoordinator: playerCoordinator)
        }
    }
}

/// The page behind a Home row: the same cards, all of them, in a grid.
struct MixedMediaPage: View {
    @Environment(\.itemRouter) private var router
    let route: MixedRowRoute
    /// The uncapped lists, handed over by the row's OWN compute pass. The page
    /// deliberately does not resolve ids itself: the row builds its items from
    /// the freshly loaded pass, so a page resolving through the global session
    /// cache could show FEWER entries than the preview above it. The exact
    /// opposite of "the page is the row, unabridged".
    let continueIds: [String]
    let addedItems: [LibraryItem]
    let musicProgress: [String: BookProgress]
    let playerCoordinator: PlayerCoordinator
    let libraryViewModel: LibraryViewModel

    /// BOTH pages use the compact grid. The XXL continue cards
    /// stacked single-column on a phone ("Blaupause Zuletzt hinzugefügt").
    private var cardWidth: CGFloat { 150 }

    /// The page shows the same mixture with a longer history.
    /// 120 is a pragmatic ceiling. The radio MRU is capped anyway and the
    /// album shelf answers a page, so beyond that there is nothing to show.
    private static let listenAgainLimit = 120

    private var listenAgainAlbums: [LibraryItem] { LateMusicValues.shared.recentAlbums }
    private var listenAgainStations: [RadioStation] {
        // Holdings display follows the holdings, never the source switch.
        RadioStore.recents()
    }
    private var listenAgainCatalog: [ContinueSources.Extra] {
        ContinueSources.positionless(in: AppStorageKeys.snapshot(),
                                     serverKnows: [],
                                     hiddenMarkers: ContinueHiddenStore.markers())
    }

    private var listenAgainEntries: [RecentlyPlayedRow.Entry] {
        RecentlyPlayedRow.merged(
            albums: listenAgainAlbums.map(\.id),
            albumTimes: RecentlyPlayedRow.albumTimes(LateMusicValues.shared.progress),
            continued: Set(continueIds),
            stations: listenAgainStations.map(\.id),
            stationTimes: RadioStore.recentTimes(),
            catalog: listenAgainCatalog.map(\.id),
            catalogTimes: RecentlyPlayedRow.catalogTimes(listenAgainCatalog),
            limit: Self.listenAgainLimit)
    }

    var body: some View {
        ScrollView {
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: cardWidth), spacing: 16, alignment: .top)],
                alignment: .leading, spacing: 20
            ) {
                switch route {
                case .continueListening:
                    // The page INHERITS the row's tap class.
                    // Continue is HOEREN, so the tile tap PLAYS (no detail in
                    // between); progress rides on the tile. F3: this one grid
                    // is THE form for every HOEREN full page (the audiobook
                    // tab's continue route lands here too).
                    ForEach(continueIds, id: \.self) { id in
                        hearTile(id)
                            .frame(width: cardWidth, alignment: .top)
                    }
                case .rediscoverPool:
                    // Registered separately (RediscoverPoolPage). Never here.
                    EmptyView()
                case .recentlyAdded:
                    ForEach(addedItems) { item in
                        HomeRecentlyAddedTile(item: item,
                                              playerCoordinator: playerCoordinator,
                                              libraryViewModel: libraryViewModel)
                            .frame(width: cardWidth, alignment: .top)
                    }
                case .listenAgain:
                    // Same mixture, same tiles, longer history. The
                    // row is the preview of THIS page (one composition rule,
                    // `RecentlyPlayedRow`, only a wider limit).
                    ForEach(listenAgainEntries, id: \.self) { entry in
                        switch entry {
                        case .album(let id):
                            if let item = listenAgainAlbums.first(where: { $0.id == id }) {
                                AlbumCell(item: item, width: cardWidth,
                                          playerCoordinator: playerCoordinator)
                                    .frame(width: cardWidth, alignment: .top)
                            }
                        case .catalogTrack(let id):
                            CatalogTrackCell(itemId: id, width: cardWidth,
                                             playerCoordinator: playerCoordinator)
                        case .station(let id):
                            if let station = listenAgainStations.first(where: { $0.id == id }) {
                                // Kachel navigiert (siehe HomeView).
                                RadioStationCard(station: station,
                                                 playerCoordinator: playerCoordinator,
                                                 width: cardWidth,
                                                 onRemoveFromRecents: {
                                                     RadioStore.removeRecentNoting(station)
                                                 })
                                    .frame(width: cardWidth, alignment: .top)
                            }
                        }
                    }
                }
            }
            .padding(.horizontal)
            .bottomBarClearance()
        }
        .navigationTitle(route.title)
        .navigationBarTitleDisplayMode(.inline)
    }

    /// One compact HOEREN tile for all three media kinds: cover + title +
    /// progress, tap plays. Long-press keeps the detail path for books.
    @ViewBuilder
    private func hearTile(_ id: String) -> some View {
        if let entry = libraryViewModel.entry(id: id) {
            MediaTile(title: entry.item.title,
                      subtitle: entry.item.author,
                      coverURL: router.coverURL(id),
                      placeholderSystemImage: "book.closed",
                      progress: entry.progress?.fraction,
                      onTap: { Task { await playerCoordinator.open(item: entry.item) } })
                .modifier(BookCellContextMenu(
                    entry: entry, playerCoordinator: playerCoordinator,
                    libraryViewModel: libraryViewModel, showsContinueHide: true))
        } else if let item = router.item(id) {
            MediaTile(title: item.title,
                      subtitle: item.author,
                      coverURL: router.coverURL(id),
                      placeholderSystemImage: MediaFamily.placeholderSymbol(
                          for: id, markedForm: ListeningStore.startedForm(id)),
                      progress: musicProgress[id]?.fraction,
                      // The server's name with two music servers (F5b-4).
                      badgeText: router.sourceLabel(id),
                      onTap: { Task { await playerCoordinator.open(item: item) } })
        }
    }
}
