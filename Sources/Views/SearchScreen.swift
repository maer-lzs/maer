// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import SwiftUI
import OSLog

/// THE global search as a FULL PAGE (no overlay, no drag handle. Y21).
/// Shown instead of the tab content while search mode is active. Content ends
/// above the bottom bar via the shared clearance (Y22); the search FIELD lives
/// in the bottom bar (Y17/Y19/Y24). On top the STANDING scope bar (Y20,
/// single select, gliding pill. The MediaTabBar pattern). An empty field
/// shows the browse deck (Y28) with the recent searches on top (Y30); typing
/// yields to the results with capped sections (Y18), the clearly set-apart
/// catalog card (Y16) and typed catalog rows (Y25).
struct SearchScreen: View {
    @Environment(\.catalogFacts) private var catalogFacts
    @ObservedObject var libraryViewModel: LibraryViewModel
    /// Owned by LibraryView (the bar types, the page renders).
    @ObservedObject var model: GlobalSearchModel
    @ObservedObject var playerCoordinator: PlayerCoordinator
    /// Owned by LibraryView. `SearchScope.initial(for:)` on open.
    @Binding var scope: SearchScope
    /// A result was chosen: the caller closes the search and navigates.
    let onOpen: (SearchResult) -> Void
    /// Category tiles navigate into the music LIBRARY pages
    /// (albums/songs/playlists/genres). The caller closes the search and
    /// pushes the route on the music tab.
    var onOpenMusicRoute: (MusicRoute) -> Void = { _ in }

    @Environment(\.pushPodcastRoute) private var pushPodcastRoute
    @Environment(\.pushFreeAudiobooksRoute) private var pushFreeAudiobooksRoute
    @Environment(\.pushLibraryListRoute) private var pushLibraryListRoute
    @State private var drill: [SearchDeckDrill] = []
    /// Explicit catalog view (via the trailing catalog-search row).
    @State private var showCatalog = false
    /// Sections the user expanded past the cap.
    @State private var expandedSections: Set<SearchResult.Kind> = []
    @State private var recents = RecentSearches.list()
    /// Everything the deck shows, built behind the door and per content
    /// change. The empty initial value lets the first open render instantly;
    /// the sections fill in as the build lands.
    @State private var deck = SearchDeck()
    @State private var pageWidth: CGFloat = 0
    @Namespace private var scopePillNS
    // The browse-deck book rows need the offline glyph like every other
    // MediaRowContent surface (the search-result rows already use isPlayableNow).
    @Environment(\.isOnline) private var isOnline

    /// A section shows at most this many hits until expanded.
    static let sectionCap = 4

    private var trimmedQuery: String {
        model.query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var isQueryActive: Bool {
        trimmedQuery.count >= GlobalSearchModel.minServerChars
    }

    /// Ranking context: the scope maps onto the tab whose sections lead.
    private var rankingTab: MediaType {
        switch scope {
        case .audiobooks: return .audiobooks
        case .podcasts: return .podcasts
        case .music: return .music
        case .radio: return .radio
        case .library: return .home
        }
    }

    var body: some View {
        VStack(spacing: 10) {
            scopeBar
                .padding(.horizontal)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        if isQueryActive {
                            resultsContent
                        } else {
                            deckContent
                        }
                    }
                    .padding(.bottom, 12)
                    .bottomBarClearance()
                    // A touch softer than the first pass (0.25 easeOut).
                    // Sections land with a gentle fade, no jump.
                    .animation(.smooth(duration: 0.35), value: model.sections)
                }
                .scrollDismissesKeyboard(.immediately)
                // A–Z jump rail (Y28, audiobooks deck root only). Floats over
                // the trailing edge, must NOT scroll with the content.
                .overlay(alignment: .trailing) {
                    if !isQueryActive, drill.isEmpty, scope == .audiobooks {
                        letterRail(proxy: proxy)
                    }
                }
            }
        }
        .background {
            GeometryReader { geo in
                Color.clear
                    .onAppear { pageWidth = geo.size.width }
                    .onChange(of: geo.size.width) { _, w in pageWidth = w }
            }
        }
        .task(id: model.query) {
            model.queryChanged(activeTab: rankingTab)
            // A new query resets the per-query view state.
            showCatalog = false
            expandedSections = []
            recents = RecentSearches.list()
        }
        .task(id: scope) {
            drill = []
            showCatalog = false
            if scope == .music || scope == .library {
                deck.artistCount = await SearchDoor.artistCount()
            }
        }
        .task(id: SearchDoor.deckToken(entries: libraryViewModel.entries)) {
            var built = await SearchDoor.deck(entries: libraryViewModel.entries)
            // The artist count travels on its own way and may have landed
            // while the build ran. Read it here, not before the await.
            built.artistCount = deck.artistCount
            deck = built
        }
    }

    // MARK: - Y20 standing scope bar (single select, gliding pill)

    /// The MediaTabBar/N1d gap: a capsule pill inset uniformly by this value
    /// IS the concentric shape inside the bar capsule.
    private static let scopePillGap: CGFloat = 6

    /// The radio scope appears only while the source is active. The
    /// isAvailable pattern, re-evaluated per render, asked at the door.
    private var visibleScopes: [SearchScope] { SearchDoor.visibleScopes() }

    private var scopeBar: some View {
        HStack(spacing: 4) {
            ForEach(visibleScopes) { candidate in
                Button {
                    scope = candidate
                } label: {
                    Text(Self.scopeLabel(candidate))
                        .font(.subheadline.weight(scope == candidate ? .semibold : .regular))
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .foregroundStyle(scope == candidate ? AnyShapeStyle(AppTheme.accent) : AnyShapeStyle(.primary))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background {
                            if scope == candidate {
                                Capsule()
                                    .fill(AppTheme.accent.opacity(0.16))
                                    .matchedGeometryEffect(id: "scopePill", in: scopePillNS)
                                    .padding(.vertical, Self.scopePillGap)
                            }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                // Locale-independent handle for the UI-test harness.
                .accessibilityIdentifier("scope-\(candidate.rawValue)")
            }
        }
        .animation(.snappy(duration: 0.3), value: scope)
        .padding(.horizontal, Self.scopePillGap)
        .modifier(AdaptiveGlassBackground(shape: Capsule()))
    }

    static func scopeLabel(_ scope: SearchScope) -> String {
        switch scope {
        case .library: return String(localized: "Library")
        case .audiobooks: return String(localized: "Audiobooks")
        case .podcasts: return String(localized: "Podcasts")
        case .music: return String(localized: "Music")
        case .radio: return String(localized: "Radio")
        }
    }

    // MARK: - Results

    @ViewBuilder
    private var resultsContent: some View {
        let own = model.sections.filter { $0.kind != .catalogShow && scope.kinds.contains($0.kind) }
        let catalog = model.sections.first { $0.kind == .catalogShow }
        let autoCatalog = own.isEmpty && !model.isSearching && !model.allSourcesFailed

        if model.allSourcesFailed {
            ContentUnavailableView(
                "Search unavailable",
                systemImage: "wifi.exclamationmark",
                description: Text("No source answered. Check your connection.")
            )
            .padding(.top, 24)
        } else if showCatalog || autoCatalog {
            // Explicit catalog view (row tap) or automatic on zero own hits.
            // Clearly labeled either way.
            if autoCatalog && !showCatalog {
                Text("No matches in your library.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 20)
                    .padding(.top, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            catalogCard(catalog)
            if model.isSearching { searchingFooter }
        } else {
            ForEach(own) { section in
                sectionView(section)
            }
            if scope.includesCatalog {
                catalogCard(catalog)
            } else {
                catalogSearchRow
            }
            if model.isSearching { searchingFooter }
        }
    }

    private var searchingFooter: some View {
        HStack {
            ProgressView()
            Text("Searching…").foregroundStyle(.secondary)
        }
        .padding(.vertical, 16)
        .frame(maxWidth: .infinity)
    }

    /// Always the last row of the library results. Jumps to the catalog.
    private var catalogSearchRow: some View {
        Button {
            withAnimation(.snappy(duration: 0.2)) { showCatalog = true }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "sparkle.magnifyingglass")
                    .foregroundStyle(AppTheme.accent)
                Text("Search the catalog for “\(trimmedQuery)”")
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 20)
            .frame(minHeight: 56)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("search-catalog-row")
    }

    /// The catalog clearly set apart. Its own grouped card, an explicit
    /// header + caption, and EVERY row carries the subscribe plus.
    @ViewBuilder
    private func catalogCard(_ section: GlobalSearchModel.Section?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            // The card names what it SHOWS. In the book scope these are
            // catalog readings, not shows. The kind title already carries
            // the right wording.
            (scope == .audiobooks
             ? Text("From the Free Catalogs")
             : Text("New Shows, from the catalog"))
                .font(.headline)
            Text("Not in your library yet")
                .font(.caption)
                .foregroundStyle(.secondary)
            if let section, !section.results.isEmpty {
                ForEach(cappedResults(section)) { result in
                    resultRow(result)
                        .padding(.horizontal, -20)   // rows bring their own padding
                }
                expandButton(section)
            } else if !model.isSearching {
                Text("No results.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 12)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.primary.opacity(0.06))
        )
        .padding(.horizontal, 12)
        .padding(.top, 10)
    }

    // MARK: - Sections (Y18 cap)

    private func cappedResults(_ section: GlobalSearchModel.Section) -> [SearchResult] {
        expandedSections.contains(section.kind)
            ? section.results
            : Array(section.results.prefix(Self.sectionCap))
    }

    @ViewBuilder
    private func expandButton(_ section: GlobalSearchModel.Section) -> some View {
        if section.results.count > Self.sectionCap, !expandedSections.contains(section.kind) {
            Button {
                withAnimation(.snappy(duration: 0.2)) {
                    _ = expandedSections.insert(section.kind)
                }
            } label: {
                Text("Show All (\(section.results.count))")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(AppTheme.accent)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 10)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    @ViewBuilder
    private func sectionView(_ section: GlobalSearchModel.Section) -> some View {
        Text(Self.sectionTitle(section.kind))
            .font(.headline)
            .padding(.horizontal, 20)
            .padding(.top, 14)
            .padding(.bottom, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
        ForEach(cappedResults(section)) { result in
            resultRow(result)
                .transition(.opacity)
        }
        expandButton(section)
    }

    // MARK: - Rows

    /// The row's cover override. Radio hits keep the gated
    /// station artwork; a CATALOG show WITHOUT its own image resolves the
    /// feed's channel artwork lazily (curated entries never pass the
    /// directory search that hands out artwork URLs). Everything else keeps
    /// the plain `coverURL` path.
    private func catalogCover(_ result: SearchResult) -> SearchRowCover? {
        SearchRowCover(result: result, placeholderSystemImage: Self.placeholder(result.kind))
    }

    /// Sender + quiet reading marker ("LibriVox · Lesung 2").
    private func catalogBookMeta(_ result: SearchResult) -> String? {
        var parts: [String] = []
        if let source = result.sourceLabel { parts.append(source) }
        if let version = catalogFacts.readingVersion(result.id) {
            parts.append(String(localized: "Reading \(version)"))
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private func resultRow(_ result: SearchResult) -> some View {
        Button {
            switch result.kind {
            // The page of the books tab, not a drill level of the search:
            // the drill was only rendered without a query, so a tap on a
            // hit did nothing visible.
            case .author:
                pushLibraryListRoute(.author(result.title))
            case .series:
                pushLibraryListRoute(.series(result.title))
            default:
                onOpen(result)
            }
        } label: {
            HStack(spacing: 8) {
                MediaRowContent(
                    coverURL: result.coverURL,
                    eyebrow: result.subtitle,
                    title: result.title,
                    titleDimmed: !result.isPlayableNow,
                    coverDimmed: !result.isPlayableNow,
                    offlineBadge: !result.isPlayableNow,
                    // Catalog hits say WHAT they are. Q1: book hits name
                    // their SENDER (LibriVox/Gutenberg/Archive), the licence
                    // capsule logic stays with the detail sheet.
                    meta: result.kind == .catalogShow ? String(localized: "Podcast")
                        : result.kind == .catalogBook ? catalogBookMeta(result) : nil,
                    placeholderSystemImage: Self.placeholder(result.kind),
                    // Mirrored shows carry the origin capsule in
                    // search too (show hits carry the feed URL as id).
                    showsOriginCapsule: result.kind == .show
                        && SearchDoor.isMirrored(feedURL: result.id),
                    // Radio hits share the ONE gated artwork
                    // (gradient+initials fallback) instead of the gray box.
                    coverOverride: catalogCover(result)
                )
                if result.kind == .author || result.kind == .series {
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                // Catalog rows carry the subscribe plus. Function AND marker;
                // own results carry nothing there.
                if result.kind == .catalogShow {
                    PodcastSubscribeBadge(feedURL: result.id)
                }
            }
            .padding(.horizontal, 20)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func bookEntryRow(_ entry: LibraryEntry) -> some View {
        SearchBookRow(entry: entry, isOnline: isOnline) {
            onOpen(SearchResult(id: entry.id, kind: .book, title: entry.item.title))
        }
    }

    // MARK: - Y28 browse deck

    @ViewBuilder
    private var deckContent: some View {
        if let level = drill.last {
            drillBackChip
            switch level {
            case .groups(_, let groups):
                ForEach(groups, id: \.name) { group in
                    deckEntryRow(title: group.name, count: group.entries.count) {
                        withAnimation(.snappy(duration: 0.2)) {
                            drill.append(.entries(title: group.name, entries: group.entries))
                        }
                    }
                }
            case .entries(_, let entries):
                ForEach(entries) { entry in
                    bookEntryRow(entry)
                }
            case .catalogShows(_, let results, let footer):
                // The SAME result row the typed search uses for catalog shows
                // (subscribe/preview routing via onOpen. No second row idiom).
                if results.isEmpty {
                    Text("No results.")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 120)
                } else {
                    ForEach(results) { resultRow($0) }
                    // Honesty line (depublication).
                    if let footer {
                        Text(footer)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 20)
                            .padding(.top, 8)
                    }
                }
            case .artists(_, let artists):
                ForEach(artists) { artist in
                    deckEntryRow(title: artist.name ?? String(localized: "Unknown Artist"), count: artist.albumCount ?? 0) {
                        onOpen(SearchDoor.hit(forArtist: artist))
                    }
                }
            }
        } else {
            recentsRow
            deckTier
            deckRaster
        }
    }

    private var drillBackChip: some View {
        HStack {
            Button {
                withAnimation(.snappy(duration: 0.2)) { _ = drill.popLast() }
            } label: {
                Label(drillTitle, systemImage: "chevron.left")
                    .font(.headline)
                    .lineLimit(1)
                    .frame(maxWidth: 260, alignment: .leading)
                    .padding(.horizontal, 12)
                    .frame(height: 44)
                    .background(Capsule().fill(Color.primary.opacity(0.08)))
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 6)
    }

    private var drillTitle: String { drill.last?.title ?? "" }

    /// The recent searches on top of the deck. Tap re-runs, long-press
    /// deletes one, "Clear" empties the list.
    @ViewBuilder
    private var recentsRow: some View {
        if !recents.isEmpty {
            HStack {
                Text("Recent Searches").font(.headline)
                Spacer()
                Button {
                    RecentSearches.clear()
                    recents = []
                } label: {
                    Text("Clear")
                        .font(.subheadline)
                        .foregroundStyle(AppTheme.accent)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 4)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(recents, id: \.self) { term in
                        Button {
                            model.query = term
                        } label: {
                            Text(term)
                                .font(.subheadline)
                                .lineLimit(1)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 8)
                                .background(Capsule().fill(Color.primary.opacity(0.08)))
                                .contentShape(Capsule())
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button(role: .destructive) {
                                RecentSearches.remove(term)
                                recents = RecentSearches.list()
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                    }
                }
                .padding(.horizontal, 20)
            }
            .padding(.bottom, 10)
        }
    }

    /// Upper tier: the drilldown entry points as tiles, a 2-column raster of
    /// glyph, title and count. WHICH tiles a scope offers and where they lead
    /// is `SearchDeckTiles`; the view renders them and performs the named
    /// destination, because only it owns the navigation path and the scope
    /// binding. The SHARED deck grid; the music tab's library list is the same
    /// component with its own entries.
    private var deckTier: some View {
        SearchDeckTier(counts: deck.counts) { counts in
            SearchDeckTiles
                .tiles(scope: scope, counts: counts)
                .map { tile in
                    CategoryDeckEntry(id: tile.id, title: tile.title,
                                      systemImage: tile.systemImage, count: tile.count) {
                        go(to: tile.destination)
                    }
                }
        }
    }

    private static let tierColumns = CategoryDeckGrid.columns

    /// Performing a named destination. Every case ends in a drill, a scope
    /// switch or a route, so a new tile cannot lead nowhere.
    private func go(to destination: SearchDeckDestination) {
        switch destination {
        case .group(let group):
            let title = Self.groupTitle(group)
            withAnimation(.snappy(duration: 0.2)) {
                drill.append(.groups(title: title, groups: groups(of: group)))
            }
        case .artists:
            Task {
                let artists = await SearchDoor.artists()
                withAnimation(.snappy(duration: 0.2)) {
                    // The artist drill lives on the music scope, so a tap in
                    // the mixed library deck moves there first.
                    if scope != .music { scope = .music }
                    drill.append(.artists(title: String(localized: "Artists"), artists: artists))
                }
            }
        case .scope(let target):
            scope = target
        case .albums:
            onOpenMusicRoute(.albums)
        case .songs:
            onOpenMusicRoute(.songs)
        case .playlists:
            // The route carries its list. Fetched fresh via the ONE
            // provider access point (junk-cleaned like everywhere).
            Task { @MainActor in
                let lists = await SearchDoor.playlists()
                onOpenMusicRoute(.playlists(lists))
            }
        case .genres:
            onOpenMusicRoute(.genres)
        case .downloaded:
            onOpenMusicRoute(.downloaded)
        case .shelf(let area):
            onOpenMusicRoute(.archiveMusic(area))
        }
    }

    private func groups(of group: SearchDeckGroup) -> [(name: String, entries: [LibraryEntry])] {
        switch group {
        case .authors: return deck.authorGroups
        case .series: return deck.seriesGroups
        case .genres: return deck.genreGroups
        }
    }

    private static func groupTitle(_ group: SearchDeckGroup) -> String {
        switch group {
        case .authors: return String(localized: "Authors")
        case .series: return String(localized: "Series")
        case .genres: return String(localized: "Genres")
        }
    }

    /// Drilldown sub-level row (still a row. The drilled lists of individual
    /// authors/series/artists are long, not a tile grid). Y43 only changed the
    /// upper ENTRY tier to tiles.
    private func deckEntryRow(title: String, count: Int, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Text(title)
                    .font(.body.weight(.medium))
                    .lineLimit(1)
                Spacer()
                Text("\(count)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 20)
            .frame(minHeight: 52)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Lower tier: cover raster (existing components)

    @ViewBuilder
    private var deckRaster: some View {
        switch scope {
        case .audiobooks:
            audiobookRaster
        case .podcasts:
            podcastGenreChips
            showRaster
        case .music:
            albumRaster
        case .radio:
            EmptyView()   // radio browses on its own tab; search is the catalog
        case .library:
            EmptyView()   // the mixed tier IS the library deck
        }
    }

    /// Podcast genre chips. The SAME CategoryTile grid as the deck tier
    /// and the music genres (one chip idiom). Tap loads the KEYLESS iTunes
    /// genre chart and drills into catalog-show rows; a failed/empty load
    /// shows "No results" in the drill (visible, rule 3).
    @State private var loadingGenreId: Int?
    private var podcastGenreChips: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("By Genre").font(.headline).padding(.horizontal, 16)
            LazyVGrid(columns: Self.tierColumns, spacing: 12) {
                // The curated public-broadcast entry. Same chip idiom,
                // drills into the DATA list (verified
                // feeds), preview/subscribe like any catalog row.
                // The tile leads to the OWN page (charts by genre +
                // curated socket) instead of the flat curation list. The
                // charts carry the bulk, the socket only what they miss.
                // The tile is the THIRD entrance to the merged page. Same
                // surface, one title everywhere.
                CategoryTile(title: String(localized: "Audiobooks and Radio Plays"),
                             systemImage: "waveform.and.mic",
                             accessibilityId: "podcast-genre-hoerspiele") {
                    pushFreeAudiobooksRoute(.area)
                }
                ForEach(PodcastGenres.curated) { genre in
                    CategoryTile(title: genre.title, systemImage: genre.systemImage,
                                 accessibilityId: "podcast-genre-\(genre.itunesGenreId)") {
                        openPodcastGenre(genre)
                    }
                    .overlay(alignment: .topTrailing) {
                        if loadingGenreId == genre.itunesGenreId {
                            ProgressView().padding(10)
                        }
                    }
                }
            }
            .padding(.horizontal, 16)
        }
        .padding(.bottom, 12)
    }

    private func openPodcastGenre(_ genre: PodcastGenre) {
        guard loadingGenreId == nil else { return }
        loadingGenreId = genre.itunesGenreId
        Task {
            let hits = await SearchDoor.topShows(genreId: genre.itunesGenreId)
            let results = hits.map { hit in
                SearchResult(id: hit.feedURL, kind: .catalogShow, title: hit.title,
                             subtitle: hit.author,
                             coverURL: hit.artworkURL.flatMap(URL.init(string:)))
            }
            loadingGenreId = nil
            withAnimation(.snappy(duration: 0.2)) {
                drill.append(.catalogShows(title: genre.title, results: results))
            }
        }
    }

    /// The LibraryView grid math (min column 108, spacing 16, padding 16).
    /// One measured width drives column count AND cell size.
    private static let minColumnWidth: CGFloat = 108
    private static let gridSpacing: CGFloat = 16
    private static let gridPadding: CGFloat = 16

    private var columnCount: Int {
        guard pageWidth > 0 else { return 3 }
        let available = pageWidth - Self.gridPadding * 2
        return max(Int((available + Self.gridSpacing) / (Self.minColumnWidth + Self.gridSpacing)), 1)
    }

    private var cellWidth: CGFloat {
        guard pageWidth > 0 else { return 132 }
        let available = pageWidth - Self.gridPadding * 2
        let totalSpacing = Self.gridSpacing * CGFloat(columnCount - 1)
        return (available - totalSpacing) / CGFloat(columnCount)
    }

    private var rasterColumns: [GridItem] {
        Array(repeating: GridItem(.fixed(cellWidth), spacing: Self.gridSpacing), count: columnCount)
    }

    /// Audiobooks: alphabetical sections with letter anchors for the A–Z rail.
    private var audiobookRaster: some View {
        ForEach(deck.letterSections, id: \.letter) { section in
            Text(section.letter)
                .font(.headline)
                .padding(.horizontal, 20)
                .padding(.bottom, 6)
                .id("letter-\(section.letter)")
            CoverGrid(columns: rasterColumns) {
                ForEach(section.entries) { entry in
                    BookGridCell(entry: entry, width: cellWidth,
                                 playerCoordinator: playerCoordinator,
                                 libraryViewModel: libraryViewModel)
                }
            }
            .padding(.horizontal, Self.gridPadding)
            .padding(.bottom, 12)
        }
    }

    private var showRaster: some View {
        CoverGrid(columns: rasterColumns) {
            ForEach(deck.shows, id: \.feedURL) { show in
                MediaTile(
                    title: show.title,
                    coverURL: show.artworkURL.flatMap { URL(string: $0) },
                    onTap: {
                        onOpen(SearchResult(id: show.feedURL, kind: .show, title: show.title))
                    }
                )
            }
        }
        .padding(.horizontal, Self.gridPadding)
    }

    private var albumRaster: some View {
        CoverGrid(columns: rasterColumns) {
            ForEach(deck.albums) { item in
                AlbumCell(item: item, width: cellWidth, playerCoordinator: playerCoordinator)
            }
        }
        .padding(.horizontal, Self.gridPadding)
    }

    /// A–Z rail: tap a letter → jump to its section.
    private func letterRail(proxy: ScrollViewProxy) -> some View {
        VStack(spacing: 1) {
            ForEach(deck.letterSections, id: \.letter) { section in
                Button {
                    withAnimation(.snappy(duration: 0.25)) {
                        proxy.scrollTo("letter-\(section.letter)", anchor: .top)
                    }
                } label: {
                    Text(section.letter)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(AppTheme.accent)
                        .frame(width: 20, height: 15)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.trailing, 1)
    }

    // MARK: - Labels

    static func sectionTitle(_ kind: SearchResult.Kind) -> String {
        switch kind {
        case .book: return String(localized: "Books")
        case .author: return String(localized: "Authors")
        case .series: return String(localized: "Series")
        case .show: return String(localized: "Shows")
        case .episode: return String(localized: "Episodes")
        case .album: return String(localized: "Albums")
        case .artist: return String(localized: "Artists")
        case .song: return String(localized: "Songs")
        case .playlist: return String(localized: "Playlists")
        case .catalogShow: return String(localized: "New Shows")
        // The card names the CONTENT and its family of senders.
        case .catalogBook: return String(localized: "From the Free Catalogs")
        case .radioStation: return String(localized: "Radio Stations")
        }
    }

    static func placeholder(_ kind: SearchResult.Kind) -> String {
        switch kind {
        case .book, .series, .catalogBook: return "book.closed"
        case .author: return "person"
        case .show, .episode, .catalogShow: return "mic"
        case .album, .song: return "music.note"
        case .playlist: return "music.note.list"
        case .artist: return "music.mic"
        case .radioStation: return "dot.radiowaves.left.and.right"
        }
    }
}

/// A book row of the browse deck. It reads whether the book lies on the
/// device (dimmed with the offline badge when it cannot play), so it observes
/// the download manager itself and the search page does not.
private struct SearchBookRow: View {
    @ObservedObject private var downloadManager = DownloadManager.shared
    let entry: LibraryEntry
    let isOnline: Bool
    let open: () -> Void

    var body: some View {
        let unavailable = MediaAvailability.offlineUnavailable(
            isConnected: isOnline,
            isDownloaded: downloadManager.isDownloaded(itemId: entry.id))
        Button(action: open) {
            MediaRowContent(
                coverURL: SearchDoor.coverURL(forItemId: entry.id),
                eyebrow: entry.item.author,
                title: entry.item.title,
                titleDimmed: unavailable,
                coverDimmed: unavailable,
                offlineBadge: unavailable,
                placeholderSystemImage: "book.closed"
            )
            .padding(.horizontal, 20)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// The upper tier of the search deck. The deck's counts come from the
/// library, except the one the library cannot know: what lies on the device,
/// counted by the SAME rule the music tab uses, so both tiles show one number.
/// That number is why this tier observes the download manager.
private struct SearchDeckTier: View {
    @ObservedObject private var downloadManager = DownloadManager.shared
    let counts: SearchDeckCounts
    let entries: (SearchDeckCounts) -> [CategoryDeckEntry]

    var body: some View {
        var withDownloads = counts
        withDownloads.downloaded = MediaFamily.musicCount(in: downloadManager.downloadedItemIds)
        return CategoryDeckGrid(entries: entries(withDownloads))
    }
}
