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
                            ForEach(column) { tile in
                                BrowseTileView(tile: tile, marksKinds: marksKinds, reason: reason,
                                               playerCoordinator: playerCoordinator)
                            }
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
}

/// One Browse tile in its own form: a show its preview, a catalog title
/// its page, a music title its album page (`CatalogDetailsPage`), on the
/// stack of the tab it stands in. Shared by the Browse row and the lanes
/// of its page.
struct BrowseTileView: View {
    let tile: BrowseTile
    /// Whether the tile carries its kind; only a row that mixes kinds asks.
    let marksKinds: Bool
    let reason: (PodcastSearchResult) -> String
    @ObservedObject var playerCoordinator: PlayerCoordinator
    @Environment(\.pushMusicRoute) private var pushMusicRoute
    @Environment(\.pushFreeAudiobooksRoute) private var pushFreeAudiobooksRoute

    var body: some View {
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
                    CollectionMenuItems.catalog(item, playerCoordinator: playerCoordinator)
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
/// a lane, or the lanes of one area behind a tab's row. A lane is the
/// section's heading with the chevron onto its existing page and its
/// tiles in one row below (`BrowseLane`), from the same stores the rows
/// read. Which sections stand is `BrowseSection.shown`, the question the
/// pages ask. In a wide window the lanes stand in two columns divided at
/// the fold (`FoldColumns`, `BrowseSection.columns`), nothing over it.
struct BrowsePage: View {
    /// Handed in by the host, which observes the store already.
    @ObservedObject var freeCatalogStore: FreeCatalogStore
    @ObservedObject var playerCoordinator: PlayerCoordinator
    /// The tab's area; nil shows every area (Start).
    var area: BrowseSection.Group? = nil
    @ObservedObject private var recommendations = PodcastRecommendationsStore.shared
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    /// The old-records lane, from the row's own query (`ShellacSection.rowTitles`).
    @State private var oldRecords: [LibraryItem] = []
    /// The charts lane: the first genre of the charts page.
    @State private var charts: [PodcastSearchResult] = []

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
        GeometryReader { geo in
            if BookDetailLayout.of(width: geo.size.width, height: geo.size.height,
                                   compactHeight: verticalSizeClass == .compact) == .twoColumns {
                let halves = BrowseSection.columns(sections)
                FoldColumns { _ in
                    // The leading column ends before the fold: its rows do
                    // not reach past it toward the side column.
                    lanes(halves.leading)
                        .environment(\.sideColumnReach, 0)
                } trailing: { _ in
                    lanes(halves.trailing,
                          continued: BrowseSection.continuedGroups(leading: halves.leading, trailing: halves.trailing))
                }
            } else {
                lanes(sections)
            }
        }
        .navigationTitle(Text("Browse"))
        .navigationBarTitleDisplayMode(.inline)
        .task(id: sections) { await load() }
    }

    /// The lanes of some sections under their area's title, in one scroll.
    /// An area `continued` from the leading column keeps its title's room
    /// here but not the title (`BrowseSection.continuedGroups`).
    private func lanes(_ shown: [BrowseSection], continued: Set<BrowseSection.Group> = []) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: TabContentLayout.sectionSpacing) {
                ForEach(BrowseSection.Group.allCases) { group in
                    let inGroup = shown.filter { $0.group == group }
                    if !inGroup.isEmpty {
                        VStack(alignment: .leading, spacing: 14) {
                            Text(Self.title(group))
                                .font(.headline).foregroundStyle(.secondary)
                                .padding(.horizontal)
                                .opacity(continued.contains(group) ? 0 : 1)
                                .accessibilityHidden(continued.contains(group))
                            ForEach(inGroup) { section in
                                BrowseLane(tiles: tiles(section), problem: problem(section),
                                           reason: reason(section), playerCoordinator: playerCoordinator) {
                                    entry(section)
                                }
                            }
                        }
                    }
                }
            }
            .padding(.top, TabContentLayout.topInset)
            .bottomBarClearance()
        }
        .reportsBottomBarScroll()
    }

    /// A lane's tiles, from the stores the tabs' rows read. An area whose
    /// switch is off asks nothing and its lane keeps the heading alone.
    private func tiles(_ section: BrowseSection) -> [BrowseTile] {
        let languages = SuggestionLanguages.current()
        switch section {
        case .recommendations:
            return PodcastShowSources.excludingOwned(recommendations.results).map(BrowseTile.recommendation)
        case .charts:
            return charts.map(BrowseTile.recommendation)
        case .classical:
            return AppStorageKeys.freeClassicalActive ? freeCatalogStore.rows.classical.map(BrowseTile.music) : []
        case .netlabels:
            return AppStorageKeys.netlabelsActive ? freeCatalogStore.rows.netlabels.map(BrowseTile.music) : []
        case .oldRecords:
            return AppStorageKeys.shellacActive ? oldRecords.map(BrowseTile.music) : []
        case .jamendo:
            return AppStorageKeys.jamendoActive ? freeCatalogStore.rows.freeMusic.map(BrowseTile.music) : []
        case .librivox:
            return freeCatalogStore.sourceRows.librivoxPopular.map { .catalog(.item($0)) }
        case .gutenberg:
            return freeCatalogStore.sourceRows.gutenberg.map { .catalog(.item($0)) }
        case .archiveBooks:
            return freeCatalogStore.sourceRows.archiveBooks.map { .catalog(.item($0)) }
        case .oldTimeRadio:
            return freeCatalogStore.sourceRows.oldTimeRadio.map { .catalog(.item($0)) }
        case .publicFeeds:
            return OERRLiveStore.feeds(for: .oerr, languages: languages).map { .catalog(.feed($0)) }
        case .independentFeeds:
            return OERRLiveStore.feeds(for: .independents, languages: languages).map { .catalog(.feed($0)) }
        }
    }

    /// Why a lane stands empty, where its store says so. Start drops the
    /// free music silently (with a log line); the page says why.
    private func problem(_ section: BrowseSection) -> String? {
        section == .jamendo && AppStorageKeys.jamendoActive ? freeCatalogStore.rows.freeMusicProblem : nil
    }

    /// The line under a show: the recommendation's reason, none for the
    /// charts.
    private func reason(_ section: BrowseSection) -> (PodcastSearchResult) -> String {
        section == .recommendations
            ? { PodcastRecommendationsStore.reasonLine(recommendations.reason(for: $0)) }
            : { _ in "" }
    }

    /// What the stores do not hold yet: the catalogs' sources, the
    /// recommendations, the old records and the charts' first genre, each
    /// only while its section stands. They load side by side
    /// (`BrowseLoad.together`); each lane fills when its own answer comes.
    private func load() async {
        #if DEBUG
        if UITestSeed.isActive { return }
        #endif
        var steps: [BrowseLoad.Step] = []
        if sections.contains(where: { $0.group == .books }) {
            steps.append { await freeCatalogStore.ensureSourcesLoaded() }
        }
        if sections.contains(.recommendations) {
            steps.append { await recommendations.refreshIfNeeded() }
        }
        if sections.contains(.oldRecords), AppStorageKeys.shellacActive, oldRecords.isEmpty {
            steps.append {
                if let titles = await ShellacSection.rowTitles() { oldRecords = titles }
            }
        }
        if sections.contains(.charts), charts.isEmpty, let chip = CatalogGenreAxis.hoerspielChips.first,
           let genreId = chip.genreIds.first {
            steps.append {
                let answer = await FetchAnswer.of("browse charts genre=\(genreId)", logger: .rss) {
                    try await ITunesDirectory().topPodcasts(genreId: genreId)
                }
                if let pool = answer.value { charts = PodcastShowSources.excludingOwned(pool) }
            }
        }
        await BrowseLoad.together(steps)
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
            RowHeading.entry("Music (Jamendo)", destination: MusicRoute.freeJamendo)
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

/// The Browse page's loads side by side: every step starts at once, and
/// the whole lasts as long as the slowest, not as long as all of them.
/// Each step publishes its own lane; none waits for another.
enum BrowseLoad {
    typealias Step = @MainActor @Sendable () async -> Void

    static func together(_ steps: [Step]) async {
        await withTaskGroup(of: Void.self) { group in
            for step in steps {
                group.addTask { await step() }
            }
        }
    }
}

/// One lane of the Browse page: the section's heading, its tiles in one
/// row below (cut like every row, the page behind the chevron holds the
/// rest), or the reason it stands empty. The tiles hold one kind and carry
/// no kind mark.
struct BrowseLane<Heading: View>: View {
    let tiles: [BrowseTile]
    var problem: String?
    let reason: (PodcastSearchResult) -> String
    @ObservedObject var playerCoordinator: PlayerCoordinator
    @ViewBuilder var heading: () -> Heading

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            heading()
            if !tiles.isEmpty {
                ScrollView(.horizontal) {
                    LazyHStack(alignment: .top, spacing: 12) {
                        ForEach(RowPreview.cut(tiles)) { tile in
                            BrowseTileView(tile: tile, marksKinds: false, reason: reason,
                                           playerCoordinator: playerCoordinator)
                                .cardRowSlot()
                        }
                    }
                    .padding(.horizontal)
                }
                .rowReachesUnderSideColumn()
            } else if let problem {
                Text(problem).font(.caption).foregroundStyle(.secondary)
                    .padding(.horizontal)
            }
        }
    }
}
