import SwiftUI

/// Full-screen search overlay in the glass look of the large player: slides up
/// from the bottom (library shows through), search field with auto-focus and
/// real-time filtering, scope chips (All/Author/Genre/Series) and result ROWS
/// with small cover thumbnails instead of a grid. Group scopes open their books
/// as a drill-down IN the overlay; a book tap closes the overlay and pushes the
/// detail page.
struct SearchOverlay: View {
    @ObservedObject var libraryViewModel: LibraryViewModel
    let provider: any AudioProvider
    /// Context: audiobooks = library search, podcasts = directory search
    /// (Apple/PodcastIndex) to subscribe. The magnifier follows the active tab.
    let mediaType: MediaType
    let topInset: CGFloat
    let presentHeight: CGFloat
    /// Book selected: the caller closes the overlay and pushes the detail page.
    let onSelect: (LibraryEntry) -> Void
    let onDismiss: () -> Void

    @ObservedObject private var podcastSubs = PodcastSubscriptions.shared
    private enum PodcastSource: Hashable { case apple, podcastIndex }
    @State private var podcastSource: PodcastSource = .apple
    @State private var podcastResults: [PodcastSearchResult] = []
    @State private var isSearchingPodcasts = false
    @State private var subscribingFeeds: Set<String> = []

    enum Scope: CaseIterable {
        case all, author, genre, series

        var label: String {
            switch self {
            case .all: return String(localized: "All")
            case .author: return String(localized: "Author")
            case .genre: return String(localized: "Genre")
            case .series: return String(localized: "Series")
            }
        }
    }

    private struct Drilldown {
        let name: String
        let entries: [LibraryEntry]
    }

    @State private var searchText = ""
    @State private var scope: Scope = .all
    @State private var drilldown: Drilldown?
    /// Ignore the keyboard safe area while closing: its simultaneous
    /// disappearance would re-layout the sheet mid-descent (visible stutter).
    @State private var isDismissing = false
    /// Offset channels as in FullPlayerOverlay: @GestureState follows the finger
    /// without delay (and resets instantly), releaseOffset drives show/hide and
    /// takes over seamlessly on release.
    @GestureState private var dragOffset: CGFloat = 0
    @State private var releaseOffset: CGFloat
    @FocusState private var searchFocused: Bool

    /// Fill for field/chips/buttons on the always-dark glass.
    private let controlFill = Color.white.opacity(0.12)
    private let selectedFill = Color.white.opacity(0.2)

    init(
        libraryViewModel: LibraryViewModel,
        provider: any AudioProvider,
        mediaType: MediaType,
        topInset: CGFloat,
        presentHeight: CGFloat,
        onSelect: @escaping (LibraryEntry) -> Void,
        onDismiss: @escaping () -> Void
    ) {
        self.libraryViewModel = libraryViewModel
        self.provider = provider
        self.mediaType = mediaType
        self.topInset = topInset
        self.presentHeight = presentHeight
        self.onSelect = onSelect
        self.onDismiss = onDismiss
        _releaseOffset = State(initialValue: presentHeight)
    }

    /// 0 (bottom) … 1 (fully presented) — controls the dim behind the sheet.
    private var presentProgress: CGFloat {
        guard presentHeight > 0 else { return 1 }
        let visibleOffset = max(0, releaseOffset + dragOffset)
        return max(0, min(1, 1 - visibleOffset / presentHeight))
    }

    var body: some View {
        ZStack {
            // Light dim between library and glass sheet — follows the
            // presentation (so pulling down brings the library back gradually)
            // and swallows touches underneath.
            Color.black.opacity(0.35 * presentProgress)
                .ignoresSafeArea()

            searchSheet
        }
        .onAppear {
            // DELIBERATELY no auto-focus: the overlay opens as a browse view
            // (lists are usable without the keyboard) — the keyboard comes only
            // when the user taps the field themselves.
            withAnimation(.spring(response: 0.45, dampingFraction: 0.9)) {
                releaseOffset = 0
            }
        }
        .accessibilityAction(.escape) { dismiss() }
    }

    private var searchSheet: some View {
        VStack(spacing: 12) {
            header
            if mediaType == .podcasts {
                if AppStorageKeys.podcastIndexConfigured { podcastSourcePicker }
                podcastResultsList
            } else {
                if drilldown == nil { scopeChips }
                resultsList
            }
        }
        // Podcast-Verzeichnis wird per Debounce gesucht (nur im Podcast-Modus).
        .task(id: searchText) {
            guard mediaType == .podcasts else { return }
            let term = searchText.trimmingCharacters(in: .whitespaces)
            guard term.count >= 2 else { podcastResults = []; return }
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled else { return }
            await runPodcastSearch(term)
        }
        .padding(.top, topInset + 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background { containerGlass }
        // The WHOLE area catches touches: without this, taps/scrolls in empty
        // areas pass THROUGH to the library (and bottom bar). Tapping empty space
        // also dismisses the keyboard; buttons and the list in the overlay keep
        // priority (child gestures win).
        .contentShape(Rectangle())
        .onTapGesture { searchFocused = false }
        .offset(y: max(0, releaseOffset + dragOffset))
        // Ignore container edges, but the KEYBOARD only while the sheet stands —
        // on close it is ignored too, otherwise its simultaneous disappearance
        // stutters into the descent.
        .ignoresSafeArea(isDismissing ? .all : .container)
        // Like the large player ALWAYS dark — "full-screen glass sheet = dark"
        // is the established design language; light text on dark glass stays
        // readable in every system scheme.
        .environment(\.colorScheme, .dark)
    }

    // MARK: - Header

    private var header: some View {
        VStack(spacing: 10) {
            Capsule()
                .fill(Color.primary.opacity(0.4))
                .frame(width: 40, height: 5)
                // Generous grab zone: the 5-pt capsule itself would be
                // practically unhittable.
                .frame(maxWidth: .infinity, minHeight: 36)
                .contentShape(Rectangle())
                .gesture(dismissDrag)

            HStack(spacing: 8) {
                if mediaType != .podcasts, let drilldown {
                    Button {
                        withAnimation(.snappy(duration: 0.2)) { self.drilldown = nil }
                    } label: {
                        Label(drilldown.name, systemImage: "chevron.left")
                            .font(.headline)
                            .lineLimit(1)
                            .padding(.horizontal, 12)
                            .frame(height: 44)
                            .background(Capsule().fill(controlFill))
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }

                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                    TextField(
                        "",
                        text: $searchText,
                        // Own prompt instead of the system color: the default
                        // placeholder gray drowns on the translucent glass.
                        prompt: Text(mediaType == .podcasts ? "Search Podcasts" : "Title, author, series")
                            .foregroundStyle(Color.white.opacity(0.65))
                    )
                    .focused($searchFocused)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .submitLabel(.search)
                    if !searchText.isEmpty {
                        Button {
                            searchText = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                                .frame(width: 32, height: 44)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 14)
                .frame(height: 44)
                .background(Capsule().fill(controlFill))

                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.body.weight(.semibold))
                        .frame(width: 44, height: 44)
                        .background(Circle().fill(controlFill))
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 16)
        }
    }

    /// Sufficiently large chips (44 pt), local state → instant reaction.
    private var scopeChips: some View {
        HStack(spacing: 8) {
            ForEach(Scope.allCases, id: \.self) { s in
                Button {
                    withAnimation(.snappy(duration: 0.18)) { scope = s }
                } label: {
                    Text(s.label)
                        .font(.subheadline.weight(scope == s ? .semibold : .regular))
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .foregroundStyle(scope == s ? AnyShapeStyle(AppTheme.accent) : AnyShapeStyle(.primary))
                        .padding(.horizontal, 16)
                        .frame(height: 44)
                        .background(Capsule().fill(scope == s ? selectedFill : controlFill))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
    }

    // MARK: - Podcast directory

    private var podcastSourcePicker: some View {
        Picker("Search source", selection: $podcastSource) {
            Text("Apple").tag(PodcastSource.apple)
            Text("PodcastIndex").tag(PodcastSource.podcastIndex)
        }
        .pickerStyle(.segmented)
        .padding(.horizontal, 16)
        .onChange(of: podcastSource) { _, _ in
            let term = searchText.trimmingCharacters(in: .whitespaces)
            if term.count >= 2 { Task { await runPodcastSearch(term) } }
        }
    }

    @ViewBuilder
    private var podcastResultsList: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                if isSearchingPodcasts {
                    HStack { ProgressView().tint(.white); Text("Searching…").foregroundStyle(.white.opacity(0.7)) }
                        .padding(.top, 24).frame(maxWidth: .infinity)
                } else if searchText.trimmingCharacters(in: .whitespaces).count < 2 {
                    Text("Search for a podcast to subscribe.")
                        .foregroundStyle(.white.opacity(0.6)).padding(.top, 32).frame(maxWidth: .infinity)
                } else if podcastResults.isEmpty {
                    emptyHint
                } else {
                    ForEach(podcastResults) { result in
                        podcastRow(result)
                        Divider().overlay(Color.white.opacity(0.1)).padding(.leading, 84)
                    }
                }
            }
            .padding(.bottom, 24)
        }
        .scrollDismissesKeyboard(.immediately)
    }

    private func podcastRow(_ result: PodcastSearchResult) -> some View {
        HStack(spacing: 12) {
            thumbnail(for: result.artworkURL.flatMap { URL(string: $0) })
            VStack(alignment: .leading, spacing: 2) {
                Text(result.title).font(.subheadline.weight(.medium)).lineLimit(1)
                if let author = result.author {
                    Text(author).font(.caption).foregroundStyle(.white.opacity(0.65)).lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            podcastSubscribeButton(result)
        }
        .padding(.horizontal, 20)
        .frame(minHeight: 64)
        .contextMenu {
            if !podcastSubs.shows.contains(where: { $0.feedURL == result.feedURL }) {
                Button {
                    subscribingFeeds.insert(result.feedURL)
                    Task {
                        _ = await podcastSubs.subscribe(urlString: result.feedURL)
                        subscribingFeeds.remove(result.feedURL)
                    }
                } label: { Label("Subscribe", systemImage: "plus.circle") }
            }
            Button {
                UIPasteboard.general.string = result.feedURL
            } label: { Label("Copy Feed URL", systemImage: "doc.on.doc") }
        }
    }

    @ViewBuilder
    private func podcastSubscribeButton(_ result: PodcastSearchResult) -> some View {
        if podcastSubs.shows.contains(where: { $0.feedURL == result.feedURL }) {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        } else if subscribingFeeds.contains(result.feedURL) {
            ProgressView().tint(.white)
        } else {
            Button("Subscribe") {
                subscribingFeeds.insert(result.feedURL)
                Task {
                    _ = await podcastSubs.subscribe(urlString: result.feedURL)
                    subscribingFeeds.remove(result.feedURL)
                }
            }
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(AppTheme.accent)
            .buttonStyle(.plain)
        }
    }

    private func runPodcastSearch(_ term: String) async {
        isSearchingPodcasts = true
        let directory: PodcastDirectory
        if podcastSource == .podcastIndex, AppStorageKeys.podcastIndexConfigured {
            directory = PodcastIndexDirectory(
                key: AppStorageKeys.podcastIndexKeyValue,
                secret: AppStorageKeys.podcastIndexSecretValue
            )
        } else {
            directory = ITunesDirectory()
        }
        podcastResults = (try? await directory.search(term)) ?? []
        isSearchingPodcasts = false
    }

    // MARK: - Results

    @ViewBuilder
    private var resultsList: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                if let drilldown {
                    rows(for: filteredBooks(drilldown.entries))
                } else {
                    switch scope {
                    case .all:
                        rows(for: filteredBooks(allBooksSorted))
                    case .author:
                        groupRows(filteredGroups(libraryViewModel.authorGroups))
                    case .genre:
                        groupRows(filteredGroups(libraryViewModel.genreGroups))
                    case .series:
                        groupRows(filteredGroups(seriesGroups))
                    }
                }
            }
            .padding(.bottom, 24)
        }
        .scrollDismissesKeyboard(.immediately)
    }

    @ViewBuilder
    private func rows(for books: [LibraryEntry]) -> some View {
        if books.isEmpty {
            emptyHint
        }
        ForEach(books) { entry in
            bookRow(entry)
            Divider()
                .overlay(Color.primary.opacity(0.12))
                .padding(.leading, 84)
        }
    }

    @ViewBuilder
    private func groupRows(_ groups: [(name: String, entries: [LibraryEntry])]) -> some View {
        if groups.isEmpty {
            emptyHint
        }
        ForEach(groups, id: \.name) { group in
            Button {
                withAnimation(.snappy(duration: 0.2)) {
                    drilldown = Drilldown(name: group.name, entries: group.entries)
                    searchText = ""
                }
            } label: {
                HStack(spacing: 12) {
                    thumbnail(for: group.entries.first)
                    Text(group.name)
                        .font(.subheadline.weight(.medium))
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    Text("\(group.entries.count)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 20)
                .frame(minHeight: 64)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Divider()
                .overlay(Color.primary.opacity(0.12))
                .padding(.leading, 84)
        }
    }

    private func bookRow(_ entry: LibraryEntry) -> some View {
        Button {
            select(entry)
        } label: {
            HStack(spacing: 12) {
                thumbnail(for: entry)
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.item.title)
                        .font(.subheadline.weight(.medium))
                        .lineLimit(1)
                    if let author = entry.item.author {
                        Text(author)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
                if let p = entry.progress {
                    Text(bookStatusText(p, duration: entry.item.media?.duration))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 20)
            .frame(minHeight: 64)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func thumbnail(for entry: LibraryEntry?) -> some View {
        let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
        Group {
            if let entry, let url = AppSession.shared.coverURL(forItemId: entry.id) {
                CachedAsyncImage(url: url, useThumbnail: true) { image in
                    image.resizable().aspectRatio(contentMode: .fill)
                } placeholder: {
                    shape.fill(Color.primary.opacity(0.08))
                }
            } else {
                shape.fill(Color.primary.opacity(0.08))
                    .overlay(Image(systemName: "book.closed").foregroundStyle(.tertiary))
            }
        }
        .frame(width: 52, height: 52)
        .clipShape(shape)
    }

    /// Cover thumbnail directly from a URL (podcast directory result).
    private func thumbnail(for url: URL?) -> some View {
        let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
        return Group {
            if let url {
                CachedAsyncImage(url: url, useThumbnail: true) { image in
                    image.resizable().aspectRatio(contentMode: .fill)
                } placeholder: {
                    shape.fill(Color.primary.opacity(0.08))
                }
            } else {
                shape.fill(Color.primary.opacity(0.08))
                    .overlay(Image(systemName: "mic").foregroundStyle(.tertiary))
            }
        }
        .frame(width: 52, height: 52)
        .clipShape(shape)
    }

    private var emptyHint: some View {
        Text("No results.")
            .foregroundStyle(.secondary)
            .padding(.top, 32)
            .frame(maxWidth: .infinity)
    }

    // MARK: - Data

    private var trimmedQuery: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Empty field = all books alphabetically (browse feel).
    private var allBooksSorted: [LibraryEntry] {
        libraryViewModel.entries.sorted {
            $0.item.title.localizedCaseInsensitiveCompare($1.item.title) == .orderedAscending
        }
    }

    /// Real-time filter over title, author, narrator and series.
    private func filteredBooks(_ books: [LibraryEntry]) -> [LibraryEntry] {
        let query = trimmedQuery
        guard !query.isEmpty else { return books }
        return books.filter { entry in
            let meta = entry.item.media?.metadata
            let fields = [entry.item.title, meta?.authorName, meta?.narratorName, meta?.seriesName]
            return fields.contains { field in
                field?.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil
            }
        }
    }

    private func filteredGroups(
        _ groups: [(name: String, entries: [LibraryEntry])]
    ) -> [(name: String, entries: [LibraryEntry])] {
        let query = trimmedQuery
        guard !query.isEmpty else { return groups }
        return groups.filter {
            $0.name.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil
        }
    }

    /// Series as (name, volumes) groups from the UNFILTERED library — search
    /// always searches everything. (`seriesGroupedEntries` applies the library
    /// filter: with the "Unfinished" filter all fully-played series would be
    /// missing here otherwise.) Grouping like the stacks (baseSeriesName,
    /// case-insensitive), volumes in series order, single-book series too.
    private var seriesGroups: [(name: String, entries: [LibraryEntry])] {
        var indexByKey: [String: Int] = [:]
        var groups: [(name: String, entries: [LibraryEntry])] = []
        // Full series name carries "#…" — localizedStandard sorts volumes
        // numerically, grouping then keeps that order per series.
        let sorted = libraryViewModel.entries.sorted {
            ($0.item.media?.metadata?.seriesName ?? "")
                .localizedStandardCompare($1.item.media?.metadata?.seriesName ?? "") == .orderedAscending
        }
        for entry in sorted {
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

    // MARK: - Dismiss

    /// Measured GLOBALLY — local coordinates of a moving layer couple back onto
    /// themselves (the stutter of the player saga).
    private var dismissDrag: some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .global)
            .updating($dragOffset) { value, state, _ in
                state = max(0, value.translation.height)
            }
            .onEnded { value in
                let end = max(0, value.translation.height)
                let shouldDismiss = end > 120 || value.predictedEndTranslation.height > 240
                // Take over the offset seamlessly (GestureState resets instantly).
                releaseOffset = end
                if shouldDismiss {
                    isDismissing = true
                    searchFocused = false
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

    private func select(_ entry: LibraryEntry) {
        isDismissing = true
        searchFocused = false
        withAnimation(.easeOut(duration: 0.3)) {
            releaseOffset = presentHeight
        } completion: {
            onSelect(entry)
        }
    }

    private func dismiss() {
        isDismissing = true
        searchFocused = false
        withAnimation(.easeOut(duration: 0.35)) {
            releaseOffset = presentHeight
        } completion: {
            onDismiss()
        }
    }

    /// Static glass like the large player: always dark-tinted, strong enough for
    /// readable lists — the library only shows through faintly. Neutral without a
    /// cover accent: search belongs to the whole library, not the currently
    /// playing book.
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
