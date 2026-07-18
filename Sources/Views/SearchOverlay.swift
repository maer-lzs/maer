import SwiftUI

/// F6: THE one global search — the magnifier behaves identically on every
/// surface (tab parity). Full-screen glass sheet (slides up, library shows
/// through) with a search field; results come from EVERY searchable provider
/// plus the "New Shows" catalog source, in typed sections whose order follows
/// the active tab (context ranking), catalog always last. One shared result
/// row (MediaRowContent family). Author/series hits drill down IN the overlay
/// (the former library-search behaviour, absorbed here); everything else
/// navigates value-based through `onOpen`.
struct SearchOverlay: View {
    @ObservedObject var libraryViewModel: LibraryViewModel
    /// Context ranking: the active tab's sections lead.
    let activeTab: MediaType
    let topInset: CGFloat
    let presentHeight: CGFloat
    /// A result was chosen: the caller closes the overlay and navigates.
    let onOpen: (SearchResult) -> Void
    let onDismiss: () -> Void

    @StateObject private var model = GlobalSearchModel.production()

    private struct Drilldown {
        let name: String
        let entries: [LibraryEntry]
    }

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

    init(
        libraryViewModel: LibraryViewModel,
        activeTab: MediaType,
        topInset: CGFloat,
        presentHeight: CGFloat,
        onOpen: @escaping (SearchResult) -> Void,
        onDismiss: @escaping () -> Void
    ) {
        self.libraryViewModel = libraryViewModel
        self.activeTab = activeTab
        self.topInset = topInset
        self.presentHeight = presentHeight
        self.onOpen = onOpen
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
            resultsList
        }
        .task(id: model.query) {
            model.queryChanged(activeTab: activeTab)
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
                if let drilldown {
                    Button {
                        withAnimation(.snappy(duration: 0.2)) { self.drilldown = nil }
                    } label: {
                        Label(drilldown.name, systemImage: "chevron.left")
                            .font(.headline)
                            .lineLimit(1)
                            // D10/B9: cap the chip so a long author/series name
                            // cannot squeeze the search field to zero width.
                            .frame(maxWidth: 180)
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
                        text: $model.query,
                        // Own prompt instead of the system color: the default
                        // placeholder gray drowns on the translucent glass.
                        prompt: Text("Search everything")
                            .foregroundStyle(Color.white.opacity(0.65))
                    )
                    .focused($searchFocused)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .submitLabel(.search)
                    if !model.query.isEmpty {
                        Button {
                            model.query = ""
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

    // MARK: - Results

    @ViewBuilder
    private var resultsList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if let drilldown {
                    ForEach(drilldown.entries) { entry in
                        bookEntryRow(entry)
                    }
                } else if model.query.trimmingCharacters(in: .whitespaces).count < GlobalSearchModel.minServerChars {
                    // Browse feel with an empty field: all books alphabetically
                    // (the pre-F6 default, kept).
                    ForEach(allBooksSorted) { entry in
                        bookEntryRow(entry)
                    }
                } else if model.allSourcesFailed {
                    ContentUnavailableView(
                        "Search unavailable",
                        systemImage: "wifi.exclamationmark",
                        description: Text("No source answered. Check your connection.")
                    )
                    .padding(.top, 24)
                } else if model.sections.isEmpty && !model.isSearching {
                    Text("No results.")
                        .foregroundStyle(.secondary)
                        .padding(.top, 32)
                        .frame(maxWidth: .infinity)
                } else {
                    ForEach(model.sections) { section in
                        sectionView(section)
                    }
                    if model.isSearching {
                        HStack {
                            ProgressView().tint(.white)
                            Text("Searching…").foregroundStyle(.white.opacity(0.7))
                        }
                        .padding(.vertical, 16)
                        .frame(maxWidth: .infinity)
                    }
                }
            }
            .padding(.bottom, 24)
        }
        .scrollDismissesKeyboard(.immediately)
    }

    @ViewBuilder
    private func sectionView(_ section: GlobalSearchModel.Section) -> some View {
        Text(Self.sectionTitle(section.kind))
            .font(.headline)
            .padding(.horizontal, 20)
            .padding(.top, 14)
            .padding(.bottom, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
        ForEach(section.results) { result in
            resultRow(result)
        }
    }

    /// ONE shared result row over the MediaRowContent family (Regel 2) —
    /// author/series drill down in the overlay, everything else goes out
    /// through `onOpen`.
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

    /// Empty field = all books alphabetically (browse feel).
    private var allBooksSorted: [LibraryEntry] {
        libraryViewModel.entries.sorted {
            $0.item.title.localizedCaseInsensitiveCompare($1.item.title) == .orderedAscending
        }
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

    private func select(_ result: SearchResult) {
        isDismissing = true
        searchFocused = false
        withAnimation(.easeOut(duration: 0.3)) {
            releaseOffset = presentHeight
        } completion: {
            onOpen(result)
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
