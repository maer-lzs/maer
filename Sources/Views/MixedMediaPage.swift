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
    case continueListening([String])
    case recentlyAdded([String])

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
    let musicProgress: [String: BookProgress]
    let playerCoordinator: PlayerCoordinator
    let libraryViewModel: LibraryViewModel

    /// Featured continue cards are wide; the added tiles are narrow. Both use
    /// the widths their row uses, so a page never re-styles what it previews.
    private var cardWidth: CGFloat {
        switch route {
        case .continueListening: CardMetrics.featuredCardWidth
        case .recentlyAdded:     150
        }
    }

    var body: some View {
        ScrollView {
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: cardWidth), spacing: 16, alignment: .top)],
                alignment: .leading, spacing: 20
            ) {
                switch route {
                case .continueListening(let ids):
                    ForEach(ids, id: \.self) { id in
                        HomeContinueCard(id: id, musicProgress: musicProgress[id],
                                         playerCoordinator: playerCoordinator,
                                         libraryViewModel: libraryViewModel)
                            .frame(width: cardWidth, alignment: .top)
                    }
                case .recentlyAdded(let ids):
                    ForEach(ids, id: \.self) { id in
                        if let item = AppSession.shared.libraryItem(forId: id) {
                            HomeRecentlyAddedTile(item: item,
                                                  playerCoordinator: playerCoordinator,
                                                  libraryViewModel: libraryViewModel)
                                .frame(width: cardWidth, alignment: .top)
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
}
