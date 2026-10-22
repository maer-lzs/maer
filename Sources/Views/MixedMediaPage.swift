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
    /// The Browse page: every foreign source as a section (`BrowsePage`).
    case browse

    /// Same wording as the row. The page IS that row, unabridged.
    var title: String {
        switch self {
        case .continueListening: String(localized: "Keep Listening")
        case .recentlyAdded:     String(localized: "Recently Added")
        case .rediscoverPool:    String(localized: "Rediscover")
        case .listenAgain:       String(localized: "Listen Again")
        case .browse:            String(localized: "Browse")
        }
    }
}

/// A Home continue card: book or podcast episode, resolved from a bare id.
/// Music never stands in Continue (`HomeSections.continueAccepts`). The row
/// renders this card; the full page deliberately takes the compact tile
/// (both pages use the compact grid, see `cardWidth`). What row and page
/// share is `HomeRecentlyAddedTile`.
struct HomeContinueCard: View {
    @Environment(\.itemRouter) private var router
    let id: String
    let playerCoordinator: PlayerCoordinator
    let libraryViewModel: LibraryViewModel

    var body: some View {
        if let entry = libraryViewModel.entry(id: id) {
            BookFeaturedCard(entry: entry,
                             playerCoordinator: playerCoordinator,
                             libraryViewModel: libraryViewModel)
                .kindGlyph(MediaFamily.kind(for: id, markedForm: ListeningStore.startedForm(id)))
        } else if let item = router.item(id) {
            PodcastFeaturedCard(item: item, playerCoordinator: playerCoordinator)
                .kindGlyph(MediaFamily.kind(for: id))
        }
    }
}

/// A "Recently Added" tile: the book cell for library books, the album cell for
/// everything else. Shared by the row and its full page.
struct HomeRecentlyAddedTile: View {
    let item: LibraryItem
    let playerCoordinator: PlayerCoordinator
    let libraryViewModel: LibraryViewModel
    /// The row's slot; the full page hands in its column's width.
    var width: CGFloat = 150

    var body: some View {
        if let entry = libraryViewModel.entry(id: item.id) {
            BookGridCell(entry: entry, width: width,
                         playerCoordinator: playerCoordinator, libraryViewModel: libraryViewModel)
                .kindGlyph(MediaFamily.kind(for: item.id, markedForm: ListeningStore.startedForm(item.id)))
        } else {
            AlbumCell(item: item, width: width, playerCoordinator: playerCoordinator)
                .kindGlyph(MediaFamily.kind(for: item.id, markedForm: ListeningStore.startedForm(item.id)))
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
    let playerCoordinator: PlayerCoordinator
    let libraryViewModel: LibraryViewModel

    /// Every route uses the compact grid; the large continue cards stood
    /// one per row on a phone. Columns of at least 150 pt, and each cell
    /// as wide as its column (`GridColumns`), measured from the page.
    private static let minimumCellWidth: CGFloat = 150
    private static let cellSpacing: CGFloat = 16
    private static let sideMargin: CGFloat = 16
    @State private var pageWidth: CGFloat = 0

    private var grid: GridColumns.Layout {
        GridColumns.layout(available: pageWidth - 2 * Self.sideMargin,
                           minimum: Self.minimumCellWidth, spacing: Self.cellSpacing)
    }

    private var cardWidth: CGFloat { grid.width }

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
        ContinueSources.positionless(positions: ListeningStore.positions(),
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
                columns: Array(repeating: GridItem(.fixed(cardWidth), spacing: Self.cellSpacing, alignment: .top),
                               count: grid.count),
                alignment: .leading, spacing: 20
            ) {
                switch route {
                case .continueListening:
                    // The page INHERITS the row's tap class.
                    // Continue is HOEREN, so the tile tap PLAYS (no detail in
                    // between); progress rides on the tile. This one grid
                    // is THE form for every HOEREN full page (the audiobook
                    // tab's continue route lands here too).
                    ForEach(continueIds, id: \.self) { id in
                        hearTile(id)
                            .frame(width: cardWidth, alignment: .top)
                    }
                case .rediscoverPool, .browse:
                    // Registered separately (RediscoverPoolPage, BrowsePage).
                    // Never here.
                    EmptyView()
                case .recentlyAdded:
                    ForEach(addedItems) { item in
                        HomeRecentlyAddedTile(item: item,
                                              playerCoordinator: playerCoordinator,
                                              libraryViewModel: libraryViewModel,
                                              width: cardWidth)
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
                                    .kindGlyph(MediaFamily.kind(for: id))
                                    .frame(width: cardWidth, alignment: .top)
                            }
                        case .catalogTrack(let id):
                            CatalogTrackCell(itemId: id, width: cardWidth,
                                             playerCoordinator: playerCoordinator)
                                .kindGlyph(MediaFamily.kind(for: id, markedForm: ListeningStore.startedForm(id)))
                        case .station(let id):
                            if let station = listenAgainStations.first(where: { $0.id == id }) {
                                // Kachel navigiert (siehe HomeView).
                                RadioStationCard(station: station,
                                                 playerCoordinator: playerCoordinator,
                                                 width: cardWidth,
                                                 onRemoveFromRecents: {
                                                     RadioStore.removeRecentNoting(station)
                                                 })
                                    .kindGlyph(.radio)
                                    .frame(width: cardWidth, alignment: .top)
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, Self.sideMargin)
            .bottomBarClearance()
        }
        .onGeometryChange(for: CGFloat.self, of: { $0.size.width }) { pageWidth = $0 }
        .navigationTitle(route.title)
        .navigationBarTitleDisplayMode(.inline)
    }

    /// One compact HOEREN tile for a book or an episode: cover + title +
    /// progress, tap plays. Long-press keeps the detail path for books.
    @ViewBuilder
    private func hearTile(_ id: String) -> some View {
        if let entry = libraryViewModel.entry(id: id) {
            MediaTile(title: entry.item.title,
                      subtitle: entry.item.author,
                      coverURL: router.coverURL(id),
                      placeholderSystemImage: "book.closed",
                      lock: .none,
                      progress: entry.progress?.fraction,
                      onTap: { Task { await playerCoordinator.open(item: entry.item) } })
                .kindGlyph(MediaFamily.kind(for: id, markedForm: ListeningStore.startedForm(id)))
                .modifier(BookCellContextMenu(
                    entry: entry, playerCoordinator: playerCoordinator,
                    libraryViewModel: libraryViewModel, showsContinueHide: true))
        } else if let item = router.item(id) {
            MediaTile(title: item.title,
                      subtitle: item.author,
                      coverURL: router.coverURL(id),
                      placeholderSystemImage: MediaFamily.placeholderSymbol(
                          for: id, markedForm: ListeningStore.startedForm(id)),
                      lock: PodcastSubscriptions.shared.lock(feedURL: PodcastShowSources.show(forEpisodeId: id)?.feedURL ?? ""),
                      onTap: { Task { await playerCoordinator.open(item: item) } })
                .kindGlyph(MediaFamily.kind(for: id, markedForm: ListeningStore.startedForm(id)))
        }
    }
}
