// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

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
    @Environment(\.pushFreeAudiobooksRoute) private var pushFreeAudiobooksRoute
    @ObservedObject var playerCoordinator: PlayerCoordinator
    @State private var detailItem: LibraryItem?

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(alignment: .top, spacing: 12) {
                ForEach(tiles) { tile in
                    tileView(tile)
                        .cardRowSlot()
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
                artworkURL: entry.artworkURL, feedURL: entry.feedURL),
                subtitle: entry.form?.label,
                badgeText: entry.ccLicense)
        case .item(let item):
            FreeCatalogBookTile(
                item: item,
                placeholderSystemImage: "waveform.and.mic",
                // Auftrag O: OTR bundles push their show page (episode list);
                // every other catalog item keeps the detail sheet.
                onTap: {
                    if FreeCatalogProvider.shared.isOldTimeRadio(itemId: item.id) {
                        pushFreeAudiobooksRoute(.series(itemId: item.id))
                    } else {
                        detailItem = item
                    }
                }
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
    @MainActor
    /// 1092867: what the LAST session showed, recorded once per session for
    /// the malus. Only a FULL row is recorded — the first calls of a session
    /// run on still-empty catalog lanes, and recording that half-row would
    /// hand next session's malus a half-truth.
    // Project default is MainActor — no explicit attribute needed here.
    private static var recordedThisSession = false

    static func hoerspieleTiles(rows: CatalogSourceLoader.SourceRows) -> [Tile] {
        let languages = SuggestionLanguages.current()
        let feedGroups = [CatalogSource.oerr, .independents]
            .map { OERRLiveStore.feeds(for: $0, languages: languages) }
        let previous = Set(UserDefaults.standard.stringArray(
            forKey: AppStorageKeys.catalogMixLastShown) ?? [])
        let tiles = row(feedGroups: feedGroups,
                        itemGroups: [rows.oldTimeRadio, rows.librivoxPopular,
                                     rows.archiveBooks, rows.gutenberg],
                        limit: RowPreview.limit,
                        seed: sessionSeed, previous: previous)
        if !recordedThisSession, tiles.count >= RowPreview.limit {
            recordedThisSession = true
            UserDefaults.standard.set(tiles.map(\.id),
                                      forKey: AppStorageKeys.catalogMixLastShown)
        }
        return tiles
    }
}
