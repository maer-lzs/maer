import SwiftUI

/// F6/Y17: THE one global search — results sheet only; the search FIELD lives
/// in the bottom bar (LibraryView), which floats above this sheet. Typed
/// sections in context order with the Y15 filter chips on top, the Y16 catalog
/// card clearly set apart, Y18 section caps, and Y13 tab-dependent browse for
/// the empty field. One shared result row (MediaRowContent family);
/// author/series drill down in the overlay, everything else navigates
/// value-based through `onOpen`.
struct SearchOverlay: View {
    @ObservedObject var libraryViewModel: LibraryViewModel
    /// Owned by LibraryView (Y17: the bar types, the overlay renders).
    @ObservedObject var model: GlobalSearchModel
    /// Context ranking + Y13 browse: the tab the magnifier was opened from.
    let activeTab: MediaType
    let topInset: CGFloat
    let presentHeight: CGFloat
    /// A result was chosen: the caller closes the overlay and navigates.
    let onOpen: (SearchResult) -> Void
    let onDismiss: () -> Void

    private struct Drilldown {
        let name: String
        let entries: [LibraryEntry]
    }

    /// Y15: chip state — starts at "Library" for every fresh search.
    @State private var chips = SearchChipFilter.start
    /// Y15: explicit catalog view (via the trailing catalog-search row).
    @State private var showCatalog = false
    /// Y18: sections the user expanded past the cap.
    @State private var expandedSections: Set<SearchResult.Kind> = []
    @State private var drilldown: Drilldown?
    @State private var isDismissing = false
    @GestureState private var dragOffset: CGFloat = 0
    @State private var releaseOffset: CGFloat

    /// Y18: a section shows at most this many hits until expanded.
    static let sectionCap = 4

    private let controlFill = Color.white.opacity(0.12)
    private let selectedFill = Color.white.opacity(0.22)

    init(
        libraryViewModel: LibraryViewModel,
        model: GlobalSearchModel,
        activeTab: MediaType,
        topInset: CGFloat,
        presentHeight: CGFloat,
        onOpen: @escaping (SearchResult) -> Void,
        onDismiss: @escaping () -> Void
    ) {
        self.libraryViewModel = libraryViewModel
        self.model = model
        self.activeTab = activeTab
        self.topInset = topInset
        self.presentHeight = presentHeight
        self.onOpen = onOpen
        self.onDismiss = onDismiss
        _releaseOffset = State(initialValue: presentHeight)
    }

    private var presentProgress: CGFloat {
        guard presentHeight > 0 else { return 1 }
        let visibleOffset = max(0, releaseOffset + dragOffset)
        return max(0, min(1, 1 - visibleOffset / presentHeight))
    }

    private var trimmedQuery: String {
        model.query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var isQueryActive: Bool {
        trimmedQuery.count >= GlobalSearchModel.minServerChars
    }

    var body: some View {
        ZStack {
            Color.black.opacity(0.35 * presentProgress)
                .ignoresSafeArea()
            searchSheet
        }
        .onAppear {
            withAnimation(.spring(response: 0.45, dampingFraction: 0.9)) {
                releaseOffset = 0
            }
        }
        .accessibilityAction(.escape) { dismiss() }
    }

    private var searchSheet: some View {
        VStack(spacing: 12) {
            dragHandle
            if drilldown == nil, isQueryActive {
                chipsRow
            }
            drilldownChip
            content
        }
        .task(id: model.query) {
            model.queryChanged(activeTab: activeTab)
            // A new query resets the per-query view state.
            showCatalog = false
            expandedSections = []
        }
        .padding(.top, topInset + 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background { containerGlass }
        .contentShape(Rectangle())
        .offset(y: max(0, releaseOffset + dragOffset))
        .ignoresSafeArea(isDismissing ? .all : .container)
        // Like the large player ALWAYS dark — "full-screen glass sheet = dark"
        // is the established design language.
        .environment(\.colorScheme, .dark)
    }

    private var dragHandle: some View {
        Capsule()
            .fill(Color.primary.opacity(0.4))
            .frame(width: 40, height: 5)
            .frame(maxWidth: .infinity, minHeight: 36)
            .contentShape(Rectangle())
            .gesture(dismissDrag)
    }

    // MARK: - Y15 chips

    private var chipsRow: some View {
        HStack(spacing: 8) {
            ForEach(SearchChip.allCases) { chip in
                Button {
                    withAnimation(.snappy(duration: 0.18)) {
                        chips = SearchChipFilter.toggled(chips, tapping: chip)
                        showCatalog = false
                    }
                } label: {
                    Text(Self.chipLabel(chip))
                        .font(.subheadline.weight(chips.contains(chip) ? .semibold : .regular))
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .foregroundStyle(chips.contains(chip) ? AnyShapeStyle(AppTheme.accent) : AnyShapeStyle(.primary))
                        .padding(.horizontal, 14)
                        .frame(height: 40)
                        .background(Capsule().fill(chips.contains(chip) ? selectedFill : controlFill))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("chip-\(chip.rawValue)")
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
    }

    @ViewBuilder
    private var drilldownChip: some View {
        if let drilldown {
            HStack {
                Button {
                    withAnimation(.snappy(duration: 0.2)) { self.drilldown = nil }
                } label: {
                    Label(drilldown.name, systemImage: "chevron.left")
                        .font(.headline)
                        .lineLimit(1)
                        .frame(maxWidth: 220, alignment: .leading)
                        .padding(.horizontal, 12)
                        .frame(height: 44)
                        .background(Capsule().fill(controlFill))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                Spacer()
            }
            .padding(.horizontal, 16)
        }
    }

    static func chipLabel(_ chip: SearchChip) -> String {
        switch chip {
        case .library: return String(localized: "Library")
        case .audiobooks: return String(localized: "Audiobooks")
        case .podcasts: return String(localized: "Podcasts")
        case .music: return String(localized: "Music")
        }
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        ScrollView {
            // Y14: calm arrival — sections animate in with a soft fade instead
            // of the list jumping on every source landing; section positions
            // are stable (fixed ranking order, kind-keyed identity).
            LazyVStack(alignment: .leading, spacing: 0) {
                if let drilldown {
                    ForEach(drilldown.entries) { entry in
                        bookEntryRow(entry)
                    }
                } else if !isQueryActive {
                    browseContent
                } else {
                    resultsContent
                }
            }
            .padding(.bottom, 24)
            .animation(.easeOut(duration: 0.25), value: model.sections)
        }
        .scrollDismissesKeyboard(.immediately)
    }

    @ViewBuilder
    private var resultsContent: some View {
        let visible = SearchChipFilter.visible(chips: chips)
        let own = model.sections.filter { $0.kind != .catalogShow && visible.kinds.contains($0.kind) }
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
            // Y15: explicit catalog view (row tap) or automatic on zero own
            // hits — clearly labeled either way.
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
            if visible.includesCatalog {
                catalogCard(catalog)
            } else {
                catalogSearchRow
            }
            if model.isSearching { searchingFooter }
        }
    }

    private var searchingFooter: some View {
        HStack {
            ProgressView().tint(.white)
            Text("Searching…").foregroundStyle(.white.opacity(0.7))
        }
        .padding(.vertical, 16)
        .frame(maxWidth: .infinity)
    }

    /// Y15: always the last row of the library results — jumps to the catalog.
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
                .fill(Color.white.opacity(0.07))
        )
        .padding(.horizontal, 12)
        .padding(.top, 10)
    }

    // MARK: - Y13 browse (empty field, per opening tab)

    @ViewBuilder
    private var browseContent: some View {
        switch activeTab {
        case .audiobooks:
            ForEach(allBooksSorted) { entry in
                bookEntryRow(entry)
            }
        case .podcasts:
            ForEach(subscribedShowResults) { result in
                resultRow(result)
            }
        case .music:
            let albums = cachedAlbumResults
            if albums.isEmpty {
                Text("Browse your music tab once — its albums then show up here.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.top, 32)
                    .frame(maxWidth: .infinity)
            } else {
                ForEach(albums) { result in
                    resultRow(result)
                }
            }
        default:
            // Home: deliberately empty ("recently searched" is a later idea).
            Text("Search everything")
                .foregroundStyle(.secondary)
                .padding(.top, 40)
                .frame(maxWidth: .infinity)
        }
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
                openDrilldown(name: result.title) { $0.item.author == result.title }
            case .series:
                openDrilldown(name: result.title) {
                    LibraryViewModel.baseSeriesName($0.item.media?.metadata?.seriesName) == result.title
                }
            default:
                select(result)
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
                // Y16: catalog rows carry the subscribe plus — function AND
                // marker; own results carry nothing there.
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
            select(SearchResult(id: entry.id, kind: .book, title: entry.item.title))
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

    private func openDrilldown(name: String, matches: (LibraryEntry) -> Bool) {
        withAnimation(.snappy(duration: 0.2)) {
            drilldown = Drilldown(name: name, entries: libraryViewModel.entries.filter(matches))
        }
    }

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

    // MARK: - Data

    /// Y13: audiobooks browse — all books alphabetically (the pre-F6 default).
    private var allBooksSorted: [LibraryEntry] {
        libraryViewModel.entries.sorted {
            $0.item.title.localizedCaseInsensitiveCompare($1.item.title) == .orderedAscending
        }
    }

    /// Y13: podcasts browse — the subscribed shows.
    private var subscribedShowResults: [SearchResult] {
        PodcastAutoContinue.allShows()
            .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
            .map { show in
                SearchResult(id: show.feedURL, kind: .show, title: show.title,
                             coverURL: show.artworkURL.flatMap { URL(string: $0) })
            }
    }

    /// Y13: music browse — the album stock this session has cached.
    private var cachedAlbumResults: [SearchResult] {
        SubsonicProvider.shared.itemsById.values
            .filter { $0.id.hasPrefix("sub:album:") }
            .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
            .map { item in
                SearchResult(id: item.id, kind: .album, title: item.title,
                             subtitle: item.author,
                             coverURL: AppSession.shared.coverURL(forItemId: item.id))
            }
    }

    // MARK: - Dismiss

    private var dismissDrag: some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .global)
            .updating($dragOffset) { value, state, _ in
                state = max(0, value.translation.height)
            }
            .onEnded { value in
                let end = max(0, value.translation.height)
                let shouldDismiss = end > 120 || value.predictedEndTranslation.height > 240
                releaseOffset = end
                if shouldDismiss {
                    isDismissing = true
                    withAnimation(.easeOut(duration: 0.35)) {
                        releaseOffset = presentHeight
                    } completion: {
                        onDismiss()
                    }
                } else {
                    withAnimation(.snappy(duration: 0.3, extraBounce: 0.04)) {
                        releaseOffset = 0
                    }
                }
            }
    }

    private func select(_ result: SearchResult) {
        isDismissing = true
        withAnimation(.easeOut(duration: 0.3)) {
            releaseOffset = presentHeight
        } completion: {
            onOpen(result)
        }
    }

    private func dismiss() {
        isDismissing = true
        withAnimation(.easeOut(duration: 0.35)) {
            releaseOffset = presentHeight
        } completion: {
            onDismiss()
        }
    }

    /// Static glass like the large player: always dark-tinted, neutral without
    /// a cover accent — search belongs to the whole library.
    @ViewBuilder
    private var containerGlass: some View {
        let shape = RoundedRectangle(cornerRadius: 28, style: .continuous)
        let tint = Color.black.opacity(0.6)
        if #available(iOS 26.0, *) {
            Color.clear
                .glassEffect(.regular.tint(tint), in: shape)
        } else {
            shape
                .fill(.ultraThinMaterial)
                .overlay(shape.fill(tint))
        }
    }
}
