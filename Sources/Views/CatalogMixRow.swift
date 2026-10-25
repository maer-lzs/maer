// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import SwiftUI

/// The ONE mixed catalog tile row. Radio-play feeds and
/// catalog titles interleaved (`CatalogMix.row`), rendered as a horizontal
/// tile row on screen-relative slots. Used by the podcast tab (the radio
/// plays to subscribe) and the audiobooks tab (the catalog row); Start
/// mixes the same tiles into its Browse row (`BrowseRow`). One tile
/// component, not two.
///
/// Tap convention: feed tiles push the show preview
/// (subscribe lives there), catalog tiles open the detail sheet with the
/// prominent Play; long-press keeps Play as the shortcut for catalog tiles.
struct CatalogMixRow: View {
    let tiles: [CatalogMix.Tile]
    @ObservedObject var playerCoordinator: PlayerCoordinator

    var body: some View {
        ScrollView(.horizontal) {
            LazyHStack(alignment: .top, spacing: 12) {
                ForEach(tiles) { tile in
                    CatalogMixTile(tile: tile, marksKind: false, playerCoordinator: playerCoordinator)
                        .cardRowSlot()
                }
            }
            .padding(.horizontal)
        }
        .rowReachesUnderSideColumn()
    }
}

/// One tile of the catalog mix: a feed tile pushes the show preview, a
/// catalog tile its page (OTR bundles their show page). Shared by the
/// tabs' rows and Start's Browse row, which mixes kinds and alone marks
/// them; the tabs' rows hold one kind each (`CatalogMix`: books no feeds,
/// podcasts no catalogs).
struct CatalogMixTile: View {
    let tile: CatalogMix.Tile
    let marksKind: Bool
    @ObservedObject var playerCoordinator: PlayerCoordinator
    @Environment(\.pushFreeAudiobooksRoute) private var pushFreeAudiobooksRoute
    @Environment(\.catalogFacts) private var catalogFacts

    var body: some View {
        switch tile {
        case .feed(let entry):
            RecommendationTile(result: PodcastSearchResult(
                title: entry.title, author: entry.author,
                artworkURL: entry.artworkURL, feedURL: entry.feedURL),
                subtitle: entry.form?.label)
                .stackedKind(marksKind ? .podcasts : nil)
        case .item(let item):
            FreeCatalogBookTile(
                item: item,
                placeholderSystemImage: "waveform.and.mic",
                // OTR bundles push their show page (episode list);
                // every other catalog item keeps the detail sheet.
                onTap: {
                    pushFreeAudiobooksRoute(catalogFacts.route(item.id))
                }
            )
            .stackedKind(marksKind ? MediaFamily.kind(for: item.id, markedForm: ListeningStore.startedForm(item.id)) : nil)
            .contextMenu {
                Button {
                    Task { await playerCoordinator.open(item: item) }
                } label: { Label("Play", systemImage: "play.fill") }
            }
        }
    }
}

extension CatalogMix {
    /// The ONE computation of the mixed audiobooks-&-radio-plays row, shared
    /// by the podcast tab and Start: curated radio-play feeds (static,
    /// instant) + the catalog title rows from the
    /// calm-gated store, fairly interleaved, capped by RowPreview.
    @MainActor
    /// What the LAST session showed, recorded once per session for
    /// the malus. Only a FULL row is recorded. The first calls of a session
    /// run on still-empty catalog lanes, and recording that half-row would
    /// hand next session's malus a half-truth.
    // Project default is MainActor. No explicit attribute needed here.
    private static var recordedThisSession = false

    /// The tiles ONE surface shows. The same tile row used to stand on three
    /// surfaces. Each surface names its own lanes and draws its own seed. The
    /// shared assembly for all three was what made the podcast tab and the
    /// start surface show the identical row under two different names.
    static func tiles(for surface: Surface,
                      rows: CatalogSourceLoader.SourceRows) -> [Tile] {
        let languages = SuggestionLanguages.current()
        let feedGroups = surface.usesFeeds
            ? [CatalogSource.oerr, .independents].map {
                OERRLiveStore.feeds(for: $0, languages: languages) }
            : []
        let itemGroups = surface.usesCatalogs
            ? [rows.oldTimeRadio, rows.librivoxPopular, rows.archiveBooks, rows.gutenberg]
            : []
        let previous = Set(AppStorageKeys.stringArray(AppStorageKeys.catalogMixLastShown) ?? [])
        let tiles = row(feedGroups: feedGroups, itemGroups: itemGroups,
                        limit: RowPreview.limit,
                        seed: seed(for: surface), previous: previous)
        // The malus is recorded from the mixed surface only: Start is the one
        // that sees both worlds, so its row is the honest record of "what did
        // the user already get shown".
        if surface == .home, !recordedThisSession, tiles.count >= RowPreview.limit {
            recordedThisSession = true
            AppStorageKeys.set(tiles.map(\.id), for: AppStorageKeys.catalogMixLastShown)
        }
        return tiles
    }
}
