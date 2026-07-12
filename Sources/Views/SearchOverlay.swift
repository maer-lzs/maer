import SwiftUI

/// Vollflächiges Such-Overlay im Glas-Look des großen Players: fährt von
/// unten hoch (Bibliothek scheint durch), Suchfeld mit Auto-Fokus und
/// Echtzeit-Filterung, Bereichs-Chips (Alle/Autor/Genre/Serie) und
/// Ergebnis-ZEILEN mit kleinen Cover-Thumbnails statt eines Grids.
/// Gruppen-Bereiche öffnen ihre Bücher als Drill-down IN der Overlay;
/// ein Buch-Tap schließt die Overlay und pusht die Detailseite.
struct SearchOverlay: View {
    @ObservedObject var libraryViewModel: LibraryViewModel
    let provider: any AudioProvider
    /// Kontext: Hörbücher = Bibliothekssuche, Podcasts = Verzeichnis-Suche
    /// (Apple/PodcastIndex) zum Abonnieren. Die Lupe folgt dem aktiven Tab.
    let mediaType: MediaType
    let topInset: CGFloat
    let presentHeight: CGFloat
    /// Buch gewählt: Aufrufer schließt die Overlay und pusht die Detailseite.
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
    /// Während des Zufahrens die Tastatur-Safe-Area ignorieren: ihr
    /// gleichzeitiges Verschwinden würde das Sheet mitten in der Abfahrt
    /// re-layouten (sichtbares Ruckeln).
    @State private var isDismissing = false
    /// Offset-Kanäle wie beim FullPlayerOverlay: @GestureState folgt dem
    /// Finger verzögerungsfrei (und resettet instant), releaseOffset fährt
    /// Ein-/Ausblenden und übernimmt beim Loslassen nahtlos.
    @GestureState private var dragOffset: CGFloat = 0
    @State private var releaseOffset: CGFloat
    @FocusState private var searchFocused: Bool

    /// Fläche für Feld/Chips/Buttons auf dem immer dunklen Glas.
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

    /// 0 (unten) … 1 (voll präsentiert) — steuert den Dim hinter dem Sheet.
    private var presentProgress: CGFloat {
        guard presentHeight > 0 else { return 1 }
        let visibleOffset = max(0, releaseOffset + dragOffset)
        return max(0, min(1, 1 - visibleOffset / presentHeight))
    }

    var body: some View {
        ZStack {
            // Leichter Dim zwischen Bibliothek und Glas-Sheet — fährt mit der
            // Präsentation mit (beim Runterziehen kommt die Bibliothek also
            // stufenlos wieder hervor) und schluckt Berührungen darunter.
            Color.black.opacity(0.35 * presentProgress)
                .ignoresSafeArea()

            searchSheet
        }
        .onAppear {
            // BEWUSST kein Auto-Fokus: die Overlay öffnet als Browse-Ansicht
            // (Listen sind ohne Tastatur nutzbar) — die Tastatur kommt erst,
            // wenn der Nutzer das Feld selbst antippt.
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
        // Die GANZE Fläche fängt Berührungen: ohne das reichen Taps/Scrolls
        // in leeren Bereichen zur Bibliothek (und Bottom-Leiste) DURCH.
        // Der Tap aufs Leere schiebt nebenbei die Tastatur weg; Buttons und
        // Liste im Overlay behalten Vorrang (Kind-Gesten gewinnen).
        .contentShape(Rectangle())
        .onTapGesture { searchFocused = false }
        .offset(y: max(0, releaseOffset + dragOffset))
        // Container-Ränder ignorieren, die TASTATUR aber nur solange das
        // Sheet steht — beim Zufahren wird sie mit ignoriert, sonst ruckelt
        // ihr gleichzeitiges Verschwinden in die Abfahrt hinein.
        .ignoresSafeArea(isDismissing ? .all : .container)
        // Wie der große Player IMMER dunkel — „vollflächiges Glas-Sheet =
        // dunkel" ist die etablierte Designsprache; heller Text auf dunklem
        // Glas bleibt in jedem System-Schema gut lesbar.
        .environment(\.colorScheme, .dark)
    }

    // MARK: - Header

    private var header: some View {
        VStack(spacing: 10) {
            Capsule()
                .fill(Color.primary.opacity(0.4))
                .frame(width: 40, height: 5)
                // Großzügige Greifzone: die 5-pt-Kapsel selbst wäre
                // praktisch untreffbar.
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
                        // Eigener Prompt statt Systemfarbe: das Standard-
                        // Placeholder-Grau säuft auf dem durchscheinenden
                        // Glas ab.
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

    /// Ausreichend große Chips (44 pt), lokaler State → sofortige Reaktion.
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

    // MARK: - Podcast-Verzeichnis

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

    // MARK: - Ergebnisse

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

    /// Cover-Thumbnail direkt aus einer URL (Podcast-Verzeichnis-Treffer).
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

    // MARK: - Daten

    private var trimmedQuery: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Leeres Feld = alle Bücher alphabetisch (Browse-Gefühl).
    private var allBooksSorted: [LibraryEntry] {
        libraryViewModel.entries.sorted {
            $0.item.title.localizedCaseInsensitiveCompare($1.item.title) == .orderedAscending
        }
    }

    /// Echtzeit-Filter über Titel, Autor, Erzähler und Serie.
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

    /// Serien als (Name, Bände)-Gruppen aus der UNGEFILTERTEN Bibliothek —
    /// die Suche durchsucht immer alles. (`seriesGroupedEntries` wendet den
    /// Bibliotheksfilter an: mit Filter „Ungehört" fehlten hier sonst alle
    /// durchgehörten Serien.) Gruppierung wie die Stapel (baseSeriesName,
    /// case-insensitiv), Bände in Serienreihenfolge, auch Ein-Buch-Serien.
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

    /// GLOBAL gemessen — lokale Koordinaten einer sich mitbewegenden Ebene
    /// koppeln auf sich selbst zurück (das Geruckel der Player-Saga).
    private var dismissDrag: some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .global)
            .updating($dragOffset) { value, state, _ in
                state = max(0, value.translation.height)
            }
            .onEnded { value in
                let end = max(0, value.translation.height)
                let shouldDismiss = end > 120 || value.predictedEndTranslation.height > 240
                // Offset nahtlos übernehmen (GestureState resettet instant).
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

    /// Statisches Glas wie beim großen Player: immer dunkel getönt, kräftig
    /// genug für gut lesbare Listen — die Bibliothek scheint nur als Ahnung
    /// durch. Neutral ohne Cover-Akzent: die Suche gehört zur ganzen
    /// Bibliothek, nicht zum gerade spielenden Buch.
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
