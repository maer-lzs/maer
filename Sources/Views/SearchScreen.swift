import SwiftUI

/// Y23: THE global search as a FULL PAGE (no overlay, no drag handle — Y21) —
/// shown instead of the tab content while search mode is active. Content ends
/// above the bottom bar via the shared clearance (Y22); the search FIELD lives
/// in the bottom bar (Y17/Y19/Y24). On top the STANDING scope bar (Y20,
/// single select, gliding pill — the MediaTabBar pattern). An empty field
/// shows the browse deck (Y28) with the recent searches on top (Y30); typing
/// yields to the results with capped sections (Y18) and the clearly
/// set-apart catalog card (Y16).
struct SearchScreen: View {
    @ObservedObject var libraryViewModel: LibraryViewModel
    /// Owned by LibraryView (the bar types, the page renders).
    @ObservedObject var model: GlobalSearchModel
    @ObservedObject var playerCoordinator: PlayerCoordinator
    /// Y20: owned by LibraryView — `SearchScope.initial(for:)` on open.
    @Binding var scope: SearchScope
    /// A result was chosen: the caller closes the search and navigates.
    let onOpen: (SearchResult) -> Void

    /// Y28: in-page drill levels of the browse deck.
    private enum DeckDrill {
        case groups(title: String, groups: [(name: String, entries: [LibraryEntry])])
        case entries(title: String, entries: [LibraryEntry])
        case artists(title: String, artists: [SubsonicArtist])
    }

    @State private var drill: [DeckDrill] = []
    /// Y15: explicit catalog view (via the trailing catalog-search row).
    @State private var showCatalog = false
    /// Y18: sections the user expanded past the cap.
    @State private var expandedSections: Set<SearchResult.Kind> = []
    @State private var recents = RecentSearches.list()
    @State private var artistCount: Int?
    @State private var pageWidth: CGFloat = 0
    @Namespace private var scopePillNS

    /// Y18: a section shows at most this many hits until expanded.
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
                    // Y14: calm arrival — sections land with a soft fade.
                    .animation(.easeOut(duration: 0.25), value: model.sections)
                }
                .scrollDismissesKeyboard(.immediately)
                // A–Z jump rail (Y28, audiobooks deck root only) — floats over
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
                artistCount = (try? await SubsonicProvider.shared.allArtists())?.count
            }
        }
    }

    // MARK: - Y20 standing scope bar (single select, gliding pill)

    /// The MediaTabBar/N1d gap: a capsule pill inset uniformly by this value
    /// IS the concentric shape inside the bar capsule.
    private static let scopePillGap: CGFloat = 6

    private var scopeBar: some View {
        HStack(spacing: 4) {
            ForEach(SearchScope.allCases) { candidate in
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
            // Explicit catalog view (row tap) or automatic on zero own hits —
            // clearly labeled either way.
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

    /// Always the last row of the library results — jumps to the catalog.
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

    /// Y16: the catalog clearly set apart — its own grouped card, an explicit
    /// header + caption, and EVERY row carries the subscribe plus.
    @ViewBuilder
    private func catalogCard(_ section: GlobalSearchModel.Section?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("New Shows — from the catalog")
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

    private func resultRow(_ result: SearchResult) -> some View {
        Button {
            switch result.kind {
            case .author:
                pushEntries(title: result.title) { $0.item.author == result.title }
            case .series:
                pushEntries(title: result.title) {
                    LibraryViewModel.baseSeriesName($0.item.media?.metadata?.seriesName) == result.title
                }
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
                    placeholderSystemImage: Self.placeholder(result.kind)
                )
                if result.kind == .author || result.kind == .series {
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                // Catalog rows carry the subscribe plus — function AND marker;
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
        Button {
            onOpen(SearchResult(id: entry.id, kind: .book, title: entry.item.title))
        } label: {
            MediaRowContent(
                coverURL: AppSession.shared.coverURL(forItemId: entry.id),
                eyebrow: entry.item.author,
                title: entry.item.title,
                placeholderSystemImage: "book.closed"
            )
            .padding(.horizontal, 20)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// Author/series hits drill IN-PAGE (results and deck share the stack).
    private func pushEntries(title: String, matches: (LibraryEntry) -> Bool) {
        withAnimation(.snappy(duration: 0.2)) {
            drill.append(.entries(title: title, entries: libraryViewModel.entries.filter(matches)))
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
            case .artists(_, let artists):
                ForEach(artists) { artist in
                    deckEntryRow(title: artist.name ?? "—", count: artist.albumCount ?? 0) {
                        // Cache the artist so the shared resolver (artist route)
                        // finds it — same path as a server search hit.
                        SubsonicProvider.shared.searchedArtistsById[artist.id] = artist
                        onOpen(SearchResult(id: "sub:artist:\(artist.id)", kind: .artist,
                                            title: artist.name ?? "—"))
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

    private var drillTitle: String {
        switch drill.last {
        case .groups(let title, _), .entries(let title, _), .artists(let title, _):
            return title
        case nil:
            return ""
        }
    }

    /// Y30: the recent searches on top of the deck — tap re-runs, long-press
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

    /// Upper tier: drilldown entry points with counts. Audiobooks get
    /// Authors/Series/Genres, music gets Artists; podcasts have none (shows
    /// ARE the unit — straight to the raster). The library scope shows the
    /// MIXED tier of all types and no giant raster below it.
    @ViewBuilder
    private var deckTier: some View {
        switch scope {
        case .audiobooks:
            audiobookTier
        case .music:
            artistTierRow
        case .podcasts:
            EmptyView()
        case .library:
            audiobookTier
            deckEntryRow(title: String(localized: "Shows"), count: subscribedShows.count) {
                scope = .podcasts
            }
            artistTierRow
            deckEntryRow(title: String(localized: "Albums"), count: cachedAlbums.count) {
                scope = .music
            }
        }
    }

    @ViewBuilder
    private var audiobookTier: some View {
        deckEntryRow(title: String(localized: "Authors"), count: libraryViewModel.authorGroups.count) {
            withAnimation(.snappy(duration: 0.2)) {
                drill.append(.groups(title: String(localized: "Authors"), groups: libraryViewModel.authorGroups))
            }
        }
        deckEntryRow(title: String(localized: "Series"), count: seriesGroups.count) {
            withAnimation(.snappy(duration: 0.2)) {
                drill.append(.groups(title: String(localized: "Series"), groups: seriesGroups))
            }
        }
        deckEntryRow(title: String(localized: "Genres"), count: libraryViewModel.genreGroups.count) {
            withAnimation(.snappy(duration: 0.2)) {
                drill.append(.groups(title: String(localized: "Genres"), groups: libraryViewModel.genreGroups))
            }
        }
    }

    private var artistTierRow: some View {
        deckEntryRow(title: String(localized: "Artists"), count: artistCount ?? 0) {
            Task {
                let artists = (try? await SubsonicProvider.shared.allArtists()) ?? []
                withAnimation(.snappy(duration: 0.2)) {
                    if scope != .music { scope = .music }
                    drill.append(.artists(title: String(localized: "Artists"), artists: artists))
                }
            }
        }
    }

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

    // MARK: - Y28 lower tier: cover raster (existing components, Regel 2)

    @ViewBuilder
    private var deckRaster: some View {
        switch scope {
        case .audiobooks:
            audiobookRaster
        case .podcasts:
            showRaster
        case .music:
            albumRaster
        case .library:
            EmptyView()   // the mixed tier IS the library deck
        }
    }

    /// The LibraryView grid math (min column 108, spacing 16, padding 16) —
    /// one measured width drives column count AND cell size.
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
        ForEach(bookLetterSections, id: \.letter) { section in
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
            ForEach(subscribedShows, id: \.feedURL) { show in
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
            ForEach(cachedAlbums) { item in
                AlbumCell(item: item, width: cellWidth, playerCoordinator: playerCoordinator)
            }
        }
        .padding(.horizontal, Self.gridPadding)
    }

    /// A–Z rail: tap a letter → jump to its section.
    private func letterRail(proxy: ScrollViewProxy) -> some View {
        VStack(spacing: 1) {
            ForEach(bookLetterSections, id: \.letter) { section in
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

    // MARK: - Data

    /// Series grouped like the author groups — key-folded dedupe, sorted.
    private var seriesGroups: [(name: String, entries: [LibraryEntry])] {
        var indexByKey: [String: Int] = [:]
        var groups: [(name: String, entries: [LibraryEntry])] = []
        for entry in libraryViewModel.entries {
            guard let name = LibraryViewModel.baseSeriesName(entry.item.media?.metadata?.seriesName) else { continue }
            let key = name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            if let idx = indexByKey[key] {
                groups[idx].entries.append(entry)
            } else {
                indexByKey[key] = groups.count
                groups.append((name: name, entries: [entry]))
            }
        }
        return groups.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private struct LetterSection {
        let letter: String
        let entries: [LibraryEntry]
    }

    /// Alphabetical, diacritic-folded; titles without a letter start land in "#".
    private var bookLetterSections: [LetterSection] {
        let sorted = libraryViewModel.entries.sorted {
            $0.item.title.localizedCaseInsensitiveCompare($1.item.title) == .orderedAscending
        }
        var sections: [LetterSection] = []
        for entry in sorted {
            let first = entry.item.title.first.map {
                String($0).folding(options: .diacriticInsensitive, locale: nil).uppercased()
            } ?? "#"
            let letter = first.rangeOfCharacter(from: .letters) != nil ? first : "#"
            if let last = sections.indices.last, sections[last].letter == letter {
                sections[last] = LetterSection(letter: letter, entries: sections[last].entries + [entry])
            } else {
                sections.append(LetterSection(letter: letter, entries: [entry]))
            }
        }
        return sections
    }

    private var subscribedShows: [PodcastShow] {
        PodcastAutoContinue.allShows()
            .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    /// The album stock this session has cached (same source as the old browse).
    private var cachedAlbums: [LibraryItem] {
        SubsonicProvider.shared.itemsById.values
            .filter { $0.id.hasPrefix("sub:album:") }
            .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
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
        case .catalogShow: return String(localized: "New Shows")
        }
    }

    static func placeholder(_ kind: SearchResult.Kind) -> String {
        switch kind {
        case .book, .series: return "book.closed"
        case .author: return "person"
        case .show, .episode, .catalogShow: return "mic"
        case .album, .song: return "music.note"
        case .artist: return "music.mic"
        }
    }
}
