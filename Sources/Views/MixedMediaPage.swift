// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

/// 3a3b1aa: the full list behind a capped Home row.
///
/// Home's rows are deliberately CROSS-MEDIA (books + episodes + music, merged
/// by recency), so their page cannot be one of the book surfaces — it would
/// silently drop the episodes and albums the row shows. Hence one page that
/// renders exactly the row's own cards, carrying the ids it previews.
nonisolated enum MixedRowRoute: Hashable {
    case continueListening
    case recentlyAdded

    /// Same wording as the row — the page IS that row, unabridged.
    var title: String {
        switch self {
        case .continueListening: String(localized: "Continue")
        case .recentlyAdded:     String(localized: "Recently Added")
        }
    }
}

/// A Home continue card: book, music (playlist/album) or podcast episode,
/// resolved from a bare id. Shared by the row and its full page (Regel 2) so
/// the two can never render different cards for the same entry.
struct HomeContinueCard: View {
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
        } else if AppSession.shared.musicProvider.owns(itemId: id),
                  [.playlist, .album].contains(AppSession.shared.musicProvider.kind(of: id)),
                  let item = AppSession.shared.libraryItem(forId: id) {
            // Package 3 + M1: playlists AND albums resume here (mosaic for
            // playlists, the album cover for albums — the card degrades to a
            // single-cover fill on its own).
            MusicContinueCard(item: item,
                              progress: musicProgress,
                              playerCoordinator: playerCoordinator)
        } else if let item = AppSession.shared.libraryItem(forId: id) {
            PodcastFeaturedCard(item: item, playerCoordinator: playerCoordinator)
        }
    }
}

/// A "Recently Added" tile: the book cell for library books, the album cell for
/// everything else. Shared by the row and its full page (Regel 2).
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
    let route: MixedRowRoute
    /// The uncapped lists, handed over by the row's OWN compute pass. The page
    /// deliberately does not resolve ids itself: the row builds its items from
    /// the freshly loaded pass, so a page resolving through the global session
    /// cache could show FEWER entries than the preview above it — the exact
    /// opposite of "the page is the row, unabridged".
    let continueIds: [String]
    let addedItems: [LibraryItem]
    let musicProgress: [String: BookProgress]
    let playerCoordinator: PlayerCoordinator
    let libraryViewModel: LibraryViewModel

    /// 75add65 F1: BOTH pages use the compact grid — the XXL continue cards
    /// stacked single-column on a phone ("Blaupause Zuletzt hinzugefügt").
    private var cardWidth: CGFloat { 150 }

    var body: some View {
        ScrollView {
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: cardWidth), spacing: 16, alignment: .top)],
                alignment: .leading, spacing: 20
            ) {
                switch route {
                case .continueListening:
                    // 75add65 F2: the page INHERITS the row's tap class —
                    // Continue is HOEREN, so the tile tap PLAYS (no detail in
                    // between); progress rides on the tile. F3: this one grid
                    // is THE form for every HOEREN full page (the audiobook
                    // tab's continue route lands here too).
                    ForEach(continueIds, id: \.self) { id in
                        hearTile(id)
                            .frame(width: cardWidth, alignment: .top)
                    }
                case .recentlyAdded:
                    ForEach(addedItems) { item in
                        HomeRecentlyAddedTile(item: item,
                                              playerCoordinator: playerCoordinator,
                                              libraryViewModel: libraryViewModel)
                            .frame(width: cardWidth, alignment: .top)
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
                      coverURL: AppSession.shared.coverURL(forItemId: id),
                      placeholderSystemImage: "book.closed",
                      progress: entry.progress?.fraction,
                      onTap: { Task { await playerCoordinator.open(item: entry.item) } })
                .modifier(BookCellContextMenu(
                    entry: entry, playerCoordinator: playerCoordinator,
                    libraryViewModel: libraryViewModel, showsContinueHide: true))
        } else if let item = AppSession.shared.libraryItem(forId: id) {
            MediaTile(title: item.title,
                      subtitle: item.author,
                      coverURL: AppSession.shared.coverURL(forItemId: id),
                      placeholderSystemImage: AppSession.shared.musicProvider.owns(itemId: id)
                          ? "music.note" : "waveform.and.mic",
                      progress: musicProgress[id]?.fraction,
                      onTap: { Task { await playerCoordinator.open(item: item) } })
        }
    }
}
