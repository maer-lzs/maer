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

    /// The kind the tile shows as, the one its mark would name.
    var kind: MediaType? {
        switch self {
        case .recommendation: .podcasts
        case .music: .music
        case .catalog(.feed): .podcasts
        case .catalog(.item(let item)):
            MediaFamily.kind(for: item.id, markedForm: ListeningStore.startedForm(item.id))
        }
    }
}

/// The Browse page of one area, pushed from a tab's Browse row. Registered
/// on every tab stack (`LibraryView.librarySurface`).
nonisolated struct BrowseRoute: Hashable {
    let area: BrowseSection.Group
}

/// The Browse row: on Start the recommendations, the free music and the
/// free audiobooks and radio plays, in a media tab the lanes of its area
/// (`TabBrowse`), as ONE double row mixed rank by rank (`BrowseMix`). Two
/// tiles per column, scrolled sideways. Every tile keeps its own tap (a
/// show its preview, a catalog title its page, a music title its album
/// page) and carries its kind where the row mixes kinds. The chevron
/// opens the Browse page, on Start with every source, in a tab with the
/// tab's area.
struct BrowseRow: View {
    let tiles: [BrowseTile]
    /// The recommendation's reason line, the one the row always had.
    let reason: (PodcastSearchResult) -> String
    @ObservedObject var playerCoordinator: PlayerCoordinator
    /// The tab's area; nil on Start.
    var area: BrowseSection.Group? = nil
    @Environment(\.pushMusicRoute) private var pushMusicRoute
    @Environment(\.pushFreeAudiobooksRoute) private var pushFreeAudiobooksRoute

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let area {
                RowHeading.entry("Browse", destination: BrowseRoute(area: area))
                    .accessibilityIdentifier("browse-\(area.rawValue)")
            } else {
                RowHeading.entry("Browse", destination: MixedRowRoute.browse)
                    .accessibilityIdentifier("home-browse")
            }
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
    }

    /// Marks only where the row mixes kinds (`BrowseMix.marksKinds`).
    private var marksKinds: Bool {
        BrowseMix.marksKinds(tiles.map(\.kind))
    }

    @ViewBuilder
    private func tileView(_ tile: BrowseTile) -> some View {
        switch tile {
        case .recommendation(let result):
            RecommendationTile(result: result, subtitle: reason(result))
                .stackedKind(marksKinds ? .podcasts : nil)
                .recommendationHideMenu(result)
        case .music(let item):
            FreeCatalogBookTile(
                item: item,
                // A work not started yet has no form; this share is music.
                placeholderSystemImage: MediaFamily.placeholderSymbol(
                    for: item.id, markedForm: ListeningStore.startedForm(item.id) ?? .album),
                onTap: {
                    CatalogDetailsPage.open(itemId: item.id, unstartedForm: .album,
                                            pushMusicRoute: pushMusicRoute,
                                            pushFreeAudiobooksRoute: pushFreeAudiobooksRoute)
                })
                .stackedKind(marksKinds ? .music : nil)
                .contextMenu {
                    Button {
                        Task { await playerCoordinator.open(item: item) }
                    } label: { Label("Play", systemImage: "play.fill") }
                    CatalogDetailsButton(itemId: item.id)
                }
        case .catalog(let tile):
            CatalogMixTile(tile: tile, marksKind: marksKinds, playerCoordinator: playerCoordinator)
        }
    }
}

/// The heading over the Browse sections a tab without a server of its
/// area carries under its own stock (`TabBrowse.Form.sections`). It heads
/// a group of rows, not a row.
struct OpenCatalogsHeading: View {
    var body: some View {
        Text("From Open Catalogs")
            .font(.title2.bold())
            .accessibilityAddTraits(.isHeader)
            .padding(.horizontal)
    }
}

/// The Browse page behind the row: every foreign catalog and directory as
/// a section pointing at its existing page, or the sections of one area
/// behind a tab's row. No logic of its own; which sections stand is
/// `BrowseSection.shown`, the question the pages ask.
struct BrowsePage: View {
    /// Handed in by the host, which observes the store already.
    @ObservedObject var freeCatalogStore: FreeCatalogStore
    /// The tab's area; nil shows every area (Start).
    var area: BrowseSection.Group? = nil

    private var sections: [BrowseSection] {
        BrowseSection.shown(in: area, isAllowed: Self.isAllowed)
    }

    /// Whether a source of a section may be asked. PodcastIndex counts
    /// only with a key, as everywhere.
    static func isAllowed(_ key: String) -> Bool {
        key == "podcastIndex"
            ? AppStorageKeys.podcastIndexActive
            : ExternalSources.source(key: key).map { ExternalSources.isAllowed($0) } ?? false
    }

    /// A tab's Browse row: one lane per section of its area that the page
    /// shows, in the page's order, mixed rank by rank. A lane whose row
    /// switch is off is handed in empty.
    static func rowTiles(in area: BrowseSection.Group,
                         lane: (BrowseSection) -> [BrowseTile]) -> [BrowseTile] {
        BrowseMix.interleave(BrowseSection.shown(in: area, isAllowed: isAllowed).map(lane),
                             limit: RowPreview.limit * 2)
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
