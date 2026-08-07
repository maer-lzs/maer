// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

/// Auftrag K + L2: the ONE mixed catalog tile row — radio-play feeds and
/// catalog titles interleaved (`CatalogMix.row`), rendered as a horizontal
/// tile row on screen-relative slots. Used by the podcast tab ("Freie
/// Hörbücher & Hörspiele") and Start ("Entdecken · Hörbücher & Hörspiele");
/// Regel 2: one component, not two mixers.
///
/// Tap convention (174f855, NACHSCHLAGEN): feed tiles push the show preview
/// (subscribe lives there), catalog tiles open the detail sheet with the
/// prominent Play; long-press keeps Play as the shortcut for catalog tiles.
struct CatalogMixRow: View {
    let tiles: [CatalogMix.Tile]
    @ObservedObject var playerCoordinator: PlayerCoordinator
    @State private var detailItem: LibraryItem?

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(alignment: .top, spacing: 12) {
                ForEach(tiles) { tile in
                    tileView(tile)
                        .containerRelativeFrame(.horizontal,
                            count: CardMetrics.recommendationColumns(regularWidth: false),
                            span: 1, spacing: 12)
                }
            }
            .padding(.horizontal)
        }
        .scrollClipDisabled()
        .sheet(item: $detailItem) { item in
            FreeCatalogDetailSheet(item: item, playerCoordinator: playerCoordinator)
        }
    }

    @ViewBuilder
    private func tileView(_ tile: CatalogMix.Tile) -> some View {
        switch tile {
        case .feed(let entry):
            RecommendationTile(result: PodcastSearchResult(
                title: entry.title, author: entry.author,
                artworkURL: nil, feedURL: entry.feedURL))
        case .item(let item):
            FreeCatalogBookTile(
                item: item,
                placeholderSystemImage: "waveform.and.mic",
                onTap: { detailItem = item }
            )
            .contextMenu {
                Button {
                    Task { await playerCoordinator.open(item: item) }
                } label: { Label("Play", systemImage: "play.fill") }
            }
        }
    }
}

extension CatalogMix {
    /// The ONE computation of the mixed audiobooks-&-radio-plays row (Auftrag
    /// K podcast tab + L2 Start share it — "keine zwei Mischer"): curated
    /// radio-play feeds (static, instant) + the catalog title rows from the
    /// calm-gated store, fairly interleaved, capped by RowPreview.
    static func hoerspieleTiles(rows: CatalogSourceLoader.SourceRows) -> [Tile] {
        let languages = SuggestionLanguages.current()
        let feedGroups = [CatalogSource.oerr, .escapeArtists, .usIndies]
            .map { $0.curatedFeeds(forLanguages: languages) }
        return row(feedGroups: feedGroups,
                   itemGroups: [rows.oldTimeRadio, rows.librivoxPopular,
                                rows.archiveBooks, rows.gutenberg],
                   limit: RowPreview.limit)
    }
}
