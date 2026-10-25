// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import SwiftUI

/// One tile of the Browse row: a recommended show, a free-music title,
/// or a tile of the catalog mix (a radio-play feed or a catalog title).
enum BrowseTile: Identifiable {
    case recommendation(PodcastSearchResult)
    case music(LibraryItem)
    case catalog(CatalogMix.Tile)

    var id: String {
        switch self {
        case .recommendation(let result): "rec:\(result.feedURL)"
        case .music(let item): "music:\(item.id)"
        case .catalog(let tile): "cat:\(tile.id)"
        }
    }
}

/// Start's Browse row: the recommendations, the free music and the free
/// audiobooks and radio plays as ONE double row, mixed rank by rank
/// (`BrowseMix`). Two tiles per column, scrolled sideways. Every tile
/// keeps its own tap (a show its preview, a catalog title its page, a
/// music title its detail sheet) and carries its kind, because the row
/// mixes kinds. The chevron opens the Browse page with every source.
struct BrowseRow: View {
    let tiles: [BrowseTile]
    /// The recommendation's reason line, the one the row always had.
    let reason: (PodcastSearchResult) -> String
    @ObservedObject var playerCoordinator: PlayerCoordinator
    @State private var detailItem: LibraryItem?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            RowHeading.entry("Browse", destination: MixedRowRoute.browse)
                .accessibilityIdentifier("home-browse")
            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: 12) {
                    ForEach(BrowseMix.columns(tiles), id: \.first?.id) { column in
                        VStack(alignment: .leading, spacing: 16) {
                            ForEach(column) { tile in tileView(tile) }
                        }
                        .cardRowSlot()
                    }
                }
                .padding(.horizontal)
            }
            .rowReachesUnderSideColumn()
        }
        .sheet(item: $detailItem) { item in
            FreeCatalogDetailSheet(item: item, playerCoordinator: playerCoordinator)
                .followsAppearanceChoice()
        }
    }

    @ViewBuilder
    private func tileView(_ tile: BrowseTile) -> some View {
        switch tile {
        case .recommendation(let result):
            RecommendationTile(result: result, subtitle: reason(result))
                .stackedKind(.podcasts)
                .recommendationHideMenu(result)
        case .music(let item):
            FreeCatalogBookTile(
                item: item,
                // A work not started yet has no form; this share is music.
                placeholderSystemImage: MediaFamily.placeholderSymbol(
                    for: item.id, markedForm: ListeningStore.startedForm(item.id) ?? .album),
                onTap: { detailItem = item })
                .stackedKind(.music)
                .contextMenu {
                    Button {
                        Task { await playerCoordinator.open(item: item) }
                    } label: { Label("Play", systemImage: "play.fill") }
                    Button {
                        detailItem = item
                    } label: { Label("Details", systemImage: "info.circle") }
                }
        case .catalog(let tile):
            CatalogMixTile(tile: tile, marksKind: true, playerCoordinator: playerCoordinator)
        }
    }
}

/// The Browse page behind the row: every foreign catalog and directory as
/// a section pointing at its existing page. No logic of its own; which
/// sections stand is `BrowseSection.shown`, the question the pages ask.
struct BrowsePage: View {
    /// Handed in by Start, which observes the store already.
    @ObservedObject var freeCatalogStore: FreeCatalogStore

    private var sections: [BrowseSection] {
        BrowseSection.shown { key in
            // PodcastIndex counts only with a key, as everywhere.
            key == "podcastIndex"
                ? AppStorageKeys.podcastIndexActive
                : ExternalSources.source(key: key).map { ExternalSources.isAllowed($0) } ?? false
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: TabContentLayout.sectionSpacing) {
                ForEach(BrowseSection.Group.allCases) { group in
                    let inGroup = sections.filter { $0.group == group }
                    if !inGroup.isEmpty {
                        VStack(alignment: .leading, spacing: 14) {
                            Text(Self.title(group))
                                .font(.headline).foregroundStyle(.secondary)
                                .padding(.horizontal)
                            ForEach(inGroup) { section in
                                entry(section)
                            }
                        }
                    }
                }
            }
            .padding(.top, TabContentLayout.topInset)
            .bottomBarClearance()
        }
        .navigationTitle(Text("Browse"))
        .navigationBarTitleDisplayMode(.inline)
    }

    private static func title(_ group: BrowseSection.Group) -> LocalizedStringKey {
        switch group {
        case .podcasts: "Podcasts"
        case .music: "Music"
        case .books: "Audiobooks and Radio Plays"
        }
    }

    @ViewBuilder
    private func entry(_ section: BrowseSection) -> some View {
        switch section {
        case .recommendations:
            RowHeading.entry("Recommended", destination: PodcastRoute.recommendations)
        case .charts:
            RowHeading.entry("Popular Radio-Play Podcasts", destination: PodcastRoute.charts)
        case .classical:
            RowHeading.entry("Classical", destination: MusicRoute.freeCatalogArea)
        case .netlabels:
            RowHeading.entry("Netlabels", destination: MusicRoute.archiveMusic(ArchiveMusicCatalog.netlabels))
        case .oldRecords:
            RowHeading.entry("Old Records", destination: MusicRoute.shellacArea)
        case .jamendo:
            VStack(alignment: .leading, spacing: 4) {
                RowHeading.entry("Music (Jamendo)", destination: MusicRoute.freeJamendo)
                // The free music's reason when it stays empty. Start drops
                // the share silently (with a log line); here it says why.
                if freeCatalogStore.rows.freeMusic.isEmpty, let problem = freeCatalogStore.rows.freeMusicProblem {
                    Text(problem).font(.caption).foregroundStyle(.secondary)
                        .padding(.horizontal)
                }
            }
        case .librivox:
            RowHeading.entry(verbatim: CatalogSource.librivox.title, destination: FreeAudiobooksRoute.source(.librivox))
        case .gutenberg:
            RowHeading.entry(verbatim: CatalogSource.gutenberg.title, destination: FreeAudiobooksRoute.source(.gutenberg))
        case .archiveBooks:
            RowHeading.entry(verbatim: CatalogSource.archiveBooks.title, destination: FreeAudiobooksRoute.source(.archiveBooks))
        case .oldTimeRadio:
            RowHeading.entry(verbatim: CatalogSource.oldTimeRadio.title, destination: FreeAudiobooksRoute.source(.oldTimeRadio))
        case .publicFeeds:
            RowHeading.entry(verbatim: CatalogSource.oerr.title, destination: FreeAudiobooksRoute.oerrCountries)
        case .independentFeeds:
            RowHeading.entry(verbatim: CatalogSource.independents.title, destination: FreeAudiobooksRoute.source(.independents))
        }
    }
}
