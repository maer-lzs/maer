import Foundation
import Combine
import OSLog

/// A book with (optional) progress — the unit the views display.
nonisolated struct LibraryEntry: Identifiable {
    let item: LibraryItem
    let progress: BookProgress?
    var id: String { item.id }
}

nonisolated enum SortOption: String, CaseIterable, Identifiable {
    case titel = "Titel"
    case autor = "Autor"
    case serie = "Serie"
    case zuletztHinzugefuegt = "Zuletzt hinzugefügt"
    case zuletztGehoert = "Zuletzt gehört"
    var id: String { rawValue }

    /// Display name (localized) — the rawValue stays the stable persistence key.
    var label: String {
        switch self {
        case .titel: return String(localized: "Title")
        case .autor: return String(localized: "Author")
        case .serie: return String(localized: "Series")
        case .zuletztHinzugefuegt: return String(localized: "Recently Added")
        case .zuletztGehoert: return String(localized: "Recently Listened")
        }
    }

    /// Sensible default direction per sort type — title/author/series
    /// alphabetically ascending (A→Z), everything time-based newest first.
    var defaultAscending: Bool {
        switch self {
        case .titel, .autor, .serie: return true
        case .zuletztHinzugefuegt, .zuletztGehoert: return false
        }
    }
}

nonisolated enum FilterOption: String, CaseIterable, Identifiable {
    case alle = "Alle"
    case unfertig = "Unfertig"
    case fertig = "Fertig"
    case heruntergeladen = "Heruntergeladen"
    var id: String { rawValue }

    /// Display name (localized) — the rawValue stays the stable persistence key.
    var label: String {
        switch self {
        case .alle: return String(localized: "All")
        case .unfertig: return String(localized: "Unfinished")
        case .fertig: return String(localized: "Finished")
        case .heruntergeladen: return String(localized: "Downloaded")
        }
    }
}

/// Persistent library cache — the reason the book list still shows even fully
/// offline (e.g. after an app restart without network) instead of being empty.
/// Top-level on purpose: nested
/// in the @MainActor class it would inherit its isolation and the detached
/// background encode could not use the Codable conformance.
/// Internal (not private) so tests can write fixture caches.
nonisolated struct LibraryDiskCache: Codable {
    let items: [LibraryItem]
    let progress: [String: BookProgress]
}

@MainActor
final class LibraryViewModel: ObservableObject {
    @Published var entries: [LibraryEntry] = [] {
        didSet { entriesStamp &+= 1 }
    }
    @Published var continueListening: [LibraryEntry] = []
    @Published var recentlyAdded: [LibraryEntry] = []
    @Published var isLoading = false
    @Published var errorMessage: String?
    /// True while the cached offline library is being shown because the server
    /// was unreachable — for a subtle UI hint instead of a hard error.
    @Published var isShowingOfflineCache = false
    /// True while further pages are still loading progressively after the first
    /// (immediately visible) page — drives the "Loading more…" footer.
    @Published var isLoadingMore = false

    /// Sort/filter are remembered in UserDefaults — so they persist across app
    /// restarts. When the user changes the sort type, the direction jumps to its
    /// sensible default (see `SortOption.defaultAscending`); the direction itself
    /// can then be flipped via the menu toggle and stays until the next sort-type
    /// change.
    @Published var sortOption: SortOption {
        didSet {
            UserDefaults.standard.set(sortOption.rawValue, forKey: Keys.sortOption)
            sortAscending = sortOption.defaultAscending
        }
    }
    @Published var filterOption: FilterOption {
        didSet { UserDefaults.standard.set(filterOption.rawValue, forKey: Keys.filterOption) }
    }
    @Published var sortAscending: Bool {
        didSet { UserDefaults.standard.set(sortAscending, forKey: Keys.sortAscending) }
    }

    private enum Keys {
        static let sortOption = AppStorageKeys.librarySortOption
        static let filterOption = AppStorageKeys.libraryFilterOption
        static let sortAscending = AppStorageKeys.librarySortAscending
    }

    private let provider: any AudioProvider
    private var cachedItems: [LibraryItem] = []
    private var libraryId: String?
    /// Server-prebuilt "Continue"/"Recently Added" rows — merged in `rebuild`
    /// with the already-loaded pages so the top rows are complete immediately and
    /// never get shorter while loading.
    private var librarySeed = LibrarySeed()
    /// Signature of the last written disk cache — avoids redundant JSON writes
    /// when items/progress have not changed.
    private var lastSavedSignature: Int?
    /// Entries last loaded via the local provider — cached so `rebuild`
    /// (synchronous, many callers) can append them without another async fetch.
    /// Updated in loadLibrary/refresh (always via the provider, never directly
    /// via LocalLibrary — otherwise it gets messy).
    private var localCache: [LibraryEntry] = []

    private let diskCacheURL: URL

    init(
        provider: any AudioProvider,
        diskCacheURL: URL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("library_cache.json")
    ) {
        self.provider = provider
        self.diskCacheURL = diskCacheURL

        let defaults = UserDefaults.standard

        // Important: keep `resolvedSortOption` as a local variable, don't read it
        // back via `self.sortOption` — Swift forbids any access via self on
        // classes before ALL stored properties (here: also the later
        // sortAscending) have a value.
        let resolvedSortOption: SortOption
        if let raw = defaults.string(forKey: Keys.sortOption), let option = SortOption(rawValue: raw) {
            resolvedSortOption = option
        } else {
            resolvedSortOption = .titel
        }
        sortOption = resolvedSortOption

        if let raw = defaults.string(forKey: Keys.filterOption), let option = FilterOption(rawValue: raw) {
            filterOption = option
        } else {
            filterOption = .alle
        }
        if defaults.object(forKey: Keys.sortAscending) != nil {
            sortAscending = defaults.bool(forKey: Keys.sortAscending)
        } else {
            sortAscending = resolvedSortOption.defaultAscending
        }
    }

    // MARK: - Memoized derived lists

    /// The sorted/grouped lists below are read from `body` — and the body can be
    /// re-evaluated very often (scroll, download ticks, playback state). The
    /// locale-aware sorts are far too expensive to run per evaluation, so both
    /// lists are memoized and recomputed only when one of their inputs changes.
    private var entriesStamp = 0
    private struct DerivedKey: Equatable {
        var stamp: Int
        var sort: SortOption
        var ascending: Bool
        var filter: FilterOption
        /// Downloads only affect the result under the "downloaded" filter; the
        /// set hash keeps the key stable otherwise.
        var downloadsHash: Int
    }
    private func derivedKey() -> DerivedKey {
        DerivedKey(
            stamp: entriesStamp, sort: sortOption, ascending: sortAscending,
            filter: filterOption,
            downloadsHash: filterOption == .heruntergeladen
                ? DownloadManager.shared.downloadedItemIds.hashValue : 0
        )
    }
    private var sortedCacheKey: DerivedKey?
    private var sortedCache: [LibraryEntry] = []
    private var groupedCacheKey: DerivedKey?
    private var groupedCache: [GridEntry] = []
    /// S16b: cache key for `downloadedEntries` — only the library revision and
    /// the downloaded-set identity affect it. Without this the Downloaded
    /// section filtered+sorted the WHOLE library on every render/section mount
    /// (LibraryView observes DownloadManager, so it re-renders often) — an
    /// O(library size) cost in the scroll path that hitched on large libraries.
    private struct DownloadedKey: Equatable { var stamp: Int; var downloadsHash: Int }
    private var downloadedCacheKey: DownloadedKey?
    private var downloadedCache: [LibraryEntry] = []

    /// The "All Books" list, prepared by the current sort, direction and filter.
    var sortedFilteredEntries: [LibraryEntry] {
        let key = derivedKey()
        if key == sortedCacheKey { return sortedCache }
        let value = computeSortedFilteredEntries()
        sortedCacheKey = key
        sortedCache = value
        return value
    }

    /// Internal (not private) so tests can compare the memoized accessor
    /// against a fresh computation.
    func computeSortedFilteredEntries() -> [LibraryEntry] {
        Self.sortedFiltered(entries: entries, sort: sortOption, ascending: sortAscending,
                            filter: filterOption,
                            downloadedIds: DownloadManager.shared.downloadedItemIds)
    }

    /// Pure sorting/filtering core — nonisolated so the off-main rebuild (S6)
    /// can pre-compute it over a snapshot.
    nonisolated static func sortedFiltered(
        entries: [LibraryEntry], sort: SortOption, ascending: Bool,
        filter: FilterOption, downloadedIds: Set<String>
    ) -> [LibraryEntry] {
        let filtered = entries.filter { matchesFilter($0, filter: filter, downloadedIds: downloadedIds) }

        // Each case deliberately returns the ASCENDING order — the direction is
        // then applied uniformly, instead of reasoning about it per case.
        let ascendingSorted: [LibraryEntry]
        switch sort {
        case .titel:
            ascendingSorted = filtered.sorted {
                $0.item.title.localizedCaseInsensitiveCompare($1.item.title) == .orderedAscending
            }
        case .autor:
            ascendingSorted = filtered.sorted {
                ($0.item.author ?? "").localizedCaseInsensitiveCompare($1.item.author ?? "") == .orderedAscending
            }
        case .serie:
            // On ABS the series name carries the sequence ("… #2");
            // localizedStandardCompare sorts #2 before #10. Books without a
            // series go to the end, alphabetically by title there.
            ascendingSorted = filtered.sorted { a, b in
                let sa = a.item.media?.metadata?.seriesName
                let sb = b.item.media?.metadata?.seriesName
                switch (sa, sb) {
                case let (x?, y?):
                    return x.localizedStandardCompare(y) == .orderedAscending
                case (_?, nil): return true
                case (nil, _?): return false
                case (nil, nil):
                    return a.item.title.localizedCaseInsensitiveCompare(b.item.title) == .orderedAscending
                }
            }
        case .zuletztHinzugefuegt:
            ascendingSorted = filtered.sorted { ($0.item.addedAt ?? 0) < ($1.item.addedAt ?? 0) }
        case .zuletztGehoert:
            ascendingSorted = filtered.sorted { ($0.progress?.lastUpdate ?? 0) < ($1.progress?.lastUpdate ?? 0) }
        }
        return ascending ? ascendingSorted : ascendingSorted.reversed()
    }

    /// Filter over a downloads SNAPSHOT: non-downloadable sources (local files)
    /// are offline-available by definition — mirrors
    /// `DownloadManager.isDownloaded` without touching main-actor state.
    nonisolated private static func matchesFilter(
        _ entry: LibraryEntry, filter: FilterOption, downloadedIds: Set<String>
    ) -> Bool {
        switch filter {
        case .alle: return true
        case .unfertig: return !(entry.progress?.isFinished ?? false)
        case .fertig: return entry.progress?.isFinished ?? false
        case .heruntergeladen:
            return entry.id.hasPrefix("local:") || downloadedIds.contains(entry.id)
        }
    }

    /// An entry in the "All Books" grid under series sorting: either a single
    /// book or a series stack.
    nonisolated enum GridEntry: Identifiable {
        case single(LibraryEntry)
        case series(name: String, entries: [LibraryEntry])
        var id: String {
            switch self {
            case .single(let e): return e.id
            case .series(let name, _): return "series-\(name)"
            }
        }
    }

    /// ABS series names carry the sequence in the name ("Series #2") —
    /// only the series name before it matters for grouping. Handles the
    /// known ABS quirks:
    /// - multiple series are comma-joined ("A #2, B #7") → use the FIRST
    /// - sequences can be ranges/dotted ("#1-3", "#2.5")
    /// - empty/whitespace names count as "no series"
    nonisolated static func baseSeriesName(_ raw: String?) -> String? {
        guard var name = raw?.trimmingCharacters(in: .whitespaces), !name.isEmpty else { return nil }
        // Multi-series: only segments that carry their own "#…" marker are
        // treated as separate series — a plain comma inside ONE series name
        // ("Krieg und Frieden, Band …") must not be split.
        let parts = name.components(separatedBy: ", ")
        if parts.count > 1, parts.dropFirst().allSatisfy({ $0.contains(" #") }) {
            name = parts[0]
        }
        if let range = name.range(of: #" ?#[\d.\-–]+$"#, options: .regularExpression) {
            name = String(name[..<range.lowerBound])
        }
        name = name.trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? nil : name
    }

    /// Grouping key: case-/diacritic-insensitive so "Foundation" and
    /// "foundation" end up in the same stack; display keeps the original.
    nonisolated private static func seriesGroupKey(_ base: String) -> String {
        base.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }

    /// sortedFilteredEntries where series with more than one book are grouped
    /// into a stack (order within: volume number, since the list already arrives
    /// sorted that way under "Series" sorting). Memoized like
    /// `sortedFilteredEntries` (two sorts + a regex per entry are far too
    /// expensive per body evaluation).
    var seriesGroupedEntries: [GridEntry] {
        let key = derivedKey()
        if key == groupedCacheKey { return groupedCache }
        let value = computeSeriesGroupedEntries()
        groupedCacheKey = key
        groupedCache = value
        return value
    }

    /// Internal (not private) — see `computeSortedFilteredEntries`.
    func computeSeriesGroupedEntries() -> [GridEntry] {
        Self.seriesGrouped(entries: entries, ascending: sortAscending, filter: filterOption,
                           downloadedIds: DownloadManager.shared.downloadedItemIds)
    }

    /// Pure series-grouping core — nonisolated for the off-main rebuild (S6).
    nonisolated static func seriesGrouped(
        entries: [LibraryEntry], ascending: Bool,
        filter: FilterOption, downloadedIds: Set<String>
    ) -> [GridEntry] {
        var result: [GridEntry] = []
        var indexByName: [String: Int] = [:]
        // Group from the UNFILTERED (but series-sorted) list so stacks always
        // stay complete — a partially filtered stack reads like missing books.
        // The filter afterwards only decides WHICH stacks/singles appear.
        let sortedAll = entries.sorted { a, b in
            let sa = a.item.media?.metadata?.seriesName
            let sb = b.item.media?.metadata?.seriesName
            switch (sa, sb) {
            case let (x?, y?): return x.localizedStandardCompare(y) == .orderedAscending
            case (_?, nil): return true
            case (nil, _?): return false
            case (nil, nil):
                return a.item.title.localizedCaseInsensitiveCompare(b.item.title) == .orderedAscending
            }
        }
        for entry in (ascending ? sortedAll : sortedAll.reversed()) {
            guard let name = Self.baseSeriesName(entry.item.media?.metadata?.seriesName) else {
                result.append(.single(entry))
                continue
            }
            let key = Self.seriesGroupKey(name)
            if let idx = indexByName[key], case .series(let existingName, let existing) = result[idx] {
                result[idx] = .series(name: existingName, entries: existing + [entry])
            } else {
                indexByName[key] = result.count
                result.append(.series(name: name, entries: [entry]))
            }
        }
        func matches(_ e: LibraryEntry) -> Bool {
            matchesFilter(e, filter: filter, downloadedIds: downloadedIds)
        }
        // Single-book „series" render as a normal book; then apply the
        // filter: singles must match, stacks stay if ANY book matches.
        return result.compactMap { item in
            if case .series(let name, let books) = item {
                if books.count == 1 {
                    return matches(books[0]) ? .single(books[0]) : nil
                }
                return books.contains(where: matches) ? .series(name: name, entries: books) : nil
            }
            if case .single(let entry) = item {
                return matches(entry) ? item : nil
            }
            return item
        }
    }

    /// Books grouped by author, alphabetically — for browsing.
    var authorGroups: [(name: String, entries: [LibraryEntry])] {
        var dict: [String: [LibraryEntry]] = [:]
        for entry in entries {
            let author = entry.item.author ?? String(localized: "Unknown Author")
            dict[author, default: []].append(entry)
        }
        return dict
            .map { (name: $0.key, entries: $0.value.sorted {
                $0.item.title.localizedCaseInsensitiveCompare($1.item.title) == .orderedAscending
            }) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Books grouped by genre — a book can appear in several genres.
    var genreGroups: [(name: String, entries: [LibraryEntry])] {
        var dict: [String: [LibraryEntry]] = [:]
        for entry in entries {
            for genre in entry.item.media?.metadata?.genres ?? [] where !genre.isEmpty {
                dict[genre, default: []].append(entry)
            }
        }
        return dict
            .map { (name: $0.key, entries: $0.value.sorted {
                $0.item.title.localizedCaseInsensitiveCompare($1.item.title) == .orderedAscending
            }) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Next unfinished book of the same series, sorted by sequence — basis
    /// for the auto-play-next setting when a book ends. nil for standalone
    /// books, unknown items, or when the series is finished.
    func nextInSeries(after itemId: String) -> LibraryEntry? {
        guard let current = entries.first(where: { $0.id == itemId }),
              let base = Self.baseSeriesName(current.item.media?.metadata?.seriesName) else { return nil }
        let key = Self.seriesGroupKey(base)
        let books = entries
            .filter { entry in
                Self.baseSeriesName(entry.item.media?.metadata?.seriesName)
                    .map(Self.seriesGroupKey) == key
            }
            // Full series name carries the "#…" sequence; localizedStandard
            // compares numerically ("#2" < "#10").
            .sorted {
                ($0.item.media?.metadata?.seriesName ?? "")
                    .localizedStandardCompare($1.item.media?.metadata?.seriesName ?? "") == .orderedAscending
            }
        guard let idx = books.firstIndex(where: { $0.id == itemId }) else { return nil }
        return books.dropFirst(idx + 1).first { !($0.progress?.isFinished ?? false) }
    }

    /// All downloaded books, alphabetically — its own section for a quick
    /// overview of "what can I listen to offline right now".
    var downloadedEntries: [LibraryEntry] {
        let key = DownloadedKey(stamp: entriesStamp,
                                downloadsHash: DownloadManager.shared.downloadedItemIds.hashValue)
        if key == downloadedCacheKey { return downloadedCache }
        // S16b: signpost the (now rare) recompute so its cost + frequency are
        // visible in Instruments — this is the main-thread work that used to run
        // on every section mount/render.
        let sp = PerfSignpost.library.beginInterval("downloadedEntries-recompute")
        let value = entries
            .filter { DownloadManager.shared.isDownloaded(itemId: $0.id) }
            .sorted { $0.item.title.localizedCaseInsensitiveCompare($1.item.title) == .orderedAscending }
        PerfSignpost.library.endInterval("downloadedEntries-recompute", sp)
        downloadedCacheKey = key
        downloadedCache = value
        return value
    }

    /// Guards against overlapping loads (pull-to-refresh + foreground
    /// refresh + reconnect can fire together → double rebuilds, visible hitch).
    private var loadInFlight = false
    /// A pull that arrives while a load runs must not vanish silently — it
    /// queues exactly one follow-up pass.
    private var reloadQueued = false
    /// True for the whole background reload, even with content on screen —
    /// drives the subtle toolbar/footer indicator.
    @Published var isRefreshing = false

    /// K1 — cache-first (stale-while-revalidate): render the last persisted
    /// library state IMMEDIATELY at cold start, before any network round-trip;
    /// `loadLibrary` then replaces it silently. Deliberately the FULL cached
    /// state (no downloaded-filtering — that belongs to the offline FALLBACK)
    /// and no offline banner (showing the cache at start is not an offline
    /// condition). No-op when entries are already showing or no cache exists.
    func showCachedLibraryIfAvailable() async {
        guard entries.isEmpty, !loadInFlight else { return }
        guard let cache = await loadDiskCache(), !cache.items.isEmpty else { return }
        await reloadLocalCache()
        isShowingOfflineCache = false
        await rebuild(items: cache.items, progress: cache.progress)
    }

    func loadLibrary() async {
        if loadInFlight {
            reloadQueued = true
            return
        }
        loadInFlight = true
        isRefreshing = true
        defer {
            loadInFlight = false
            isRefreshing = false
            // A pull that arrived mid-load runs one follow-up pass.
            if reloadQueued {
                reloadQueued = false
                Task { await self.loadLibrary() }
            }
        }
        // Spinner only when there is nothing on screen yet (first install /
        // no cache) — with the cache-first render the network load runs silently.
        isLoading = entries.isEmpty
        errorMessage = nil
        defer { isLoading = false }
        // Local source always first (in-memory, never an error) — so local
        // titles are there even when the server is offline.
        await reloadLocalCache()
        do {
            // K2 — skip the first serial round-trip: with a stored library id,
            // start progress/seed/first page immediately and only VALIDATE the
            // library list in parallel. If the stored library vanished, fall
            // back to today's resolve-then-load behavior.
            let storedId = UserDefaults.standard.string(forKey: AppStorageKeys.selectedLibraryId)
            if let storedId {
                async let validationTask: [ABSLibrary]? = try? await withRetry {
                    try await self.provider.fetchLibraries()
                }.filter { !$0.isPodcast }
                do {
                    try await loadContent(libraryId: storedId)
                    // Late validation: the id no longer exists → reload properly.
                    if let libraries = await validationTask,
                       !libraries.contains(where: { $0.id == storedId }) {
                        try await resolveAndLoad(libraries: libraries)
                    }
                } catch {
                    // The direct load failed — maybe the stored library is gone
                    // (e.g. 404). If validation can name a replacement, use it;
                    // a real offline error falls through to the cache fallback.
                    guard let libraries = await validationTask,
                          !libraries.contains(where: { $0.id == storedId }) else { throw error }
                    try await resolveAndLoad(libraries: libraries)
                }
            } else {
                // ONLY book libraries for the audiobook tab — podcast libraries
                // belong to the podcast provider. Retry transient errors briefly
                // (timeout/5xx) before the offline/cache fallback; real offline
                // errors and 401 still throw immediately.
                let libraries = try await withRetry { try await self.provider.fetchLibraries() }
                    .filter { !$0.isPodcast }
                try await resolveAndLoad(libraries: libraries)
            }
        } catch {
            // Only treat real network unreachability as "offline" — another
            // error (e.g. server hang, broken format) must not wrongly show the
            // offline hint when there actually is a connection.
            if NetworkStatus.isOfflineError(error), let cache = await loadDiskCache() {
                // Don't race the startup download scan — playability/dimming of
                // the offline view depends on a complete downloaded set.
                await DownloadManager.shared.ensureScanned()
                isShowingOfflineCache = true
                // B2 (user decision): offline shows the WHOLE library (last
                // cached state) + banner; titles that aren't downloaded are
                // dimmed reactively in the cells instead of being filtered out.
                await rebuild(items: cache.items, progress: cache.progress)
            } else if let cache = await loadDiskCache() {
                // Another error, but a cache exists: keep showing the last known
                // state silently, without a misleading offline hint — including
                // clearing a leftover hint from an earlier offline load.
                isShowingOfflineCache = false
                await rebuild(items: cache.items, progress: cache.progress)
            } else {
                errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
    }

    /// Resolve the library (settings choice wins, else the first) and load it.
    private func resolveAndLoad(libraries: [ABSLibrary]) async throws {
        let storedId = UserDefaults.standard.string(forKey: AppStorageKeys.selectedLibraryId)
        guard let library = libraries.first(where: { $0.id == storedId }) ?? libraries.first else {
            errorMessage = String(localized: "No library found on the server.")
            return
        }
        try await loadContent(libraryId: library.id)
    }

    /// Full progressive content load of one library: progress + seed in
    /// parallel, first page immediately, remaining pages quietly, disk cache and
    /// key cleanup only when complete. Extracted so the K2 fast path (stored
    /// library id, no prior fetchLibraries round-trip) shares one implementation
    /// with the resolve path.
    private func loadContent(libraryId id: String) async throws {
        async let progressTask = provider.fetchAllProgress()
        // Prebuilt "Continue"/"Recently Added" rows from the server (one small
        // request) — so the top rows are complete IMMEDIATELY, regardless of
        // which page a started book is on.
        async let seedTask = provider.fetchLibrarySeed(libraryId: id)

        // Progressive loading: show the first page immediately, append the
        // rest page by page in the background. All client-side functions
        // (sort, filter, series stacks, search) work on what is already
        // loaded and complete themselves as more pages arrive.
        let pageSize = 50
        let first = try await withRetry {
            try await self.provider.fetchLibraryItemsPage(libraryId: id, limit: pageSize, page: 0)
        }
        let progress = (try? await progressTask) ?? [:]
        librarySeed = (try? await seedTask) ?? LibrarySeed()

        libraryId = id
        isShowingOfflineCache = false
        var accumulated = first.items
        let total = first.total
        // Render partial pages ONLY when nothing is on screen yet (fresh install
        // / no cache) — there a fast first page beats a blank wait, and the grid
        // only grows. With a cache already showing the full library, a partial
        // page would SHRINK the grid (221 → 50 → …) and flash: skip the partial
        // rebuilds and publish once at the end instead.
        let renderPartialPages = entries.isEmpty
        if renderPartialPages {
            await rebuild(items: accumulated, progress: progress)
            isLoadingMore = accumulated.count < total
        }
        isLoading = false   // first view is ready — spinner off, rest loads quietly

        // Append the remaining pages (in the same load). A network drop
        // mid-load keeps what is already shown instead of jumping to the
        // offline fallback. Intermediate rebuilds are throttled (only every
        // 3rd page) — a guaranteed final rebuild afterwards keeps the result
        // identical but saves intermediate work.
        var page = 1
        do {
            while accumulated.count < total {
                let next = try await provider.fetchLibraryItemsPage(
                    libraryId: id, limit: pageSize, page: page)
                if next.items.isEmpty { break }
                accumulated += next.items
                page += 1
                if renderPartialPages, page % 3 == 0 {
                    await rebuild(items: accumulated, progress: progress)
                }
            }
        } catch {
            // Abort while loading more: keep the loaded partial list.
        }
        await rebuild(items: accumulated, progress: progress)   // final rebuild
        isLoadingMore = false

        // Only persist/clean up with a FULLY loaded list — otherwise a
        // partial list would overwrite the good offline cache, or (cleanup)
        // wrongly delete per-book keys of not-yet-loaded books.
        if accumulated.count >= total {
            saveLibraryDiskCache(items: accumulated, progress: progress)
            let validIds = Set(accumulated.map(\.id))
            Task.detached(priority: .utility) {
                AppStorageKeys.cleanupPerBookKeys(validItemIds: validIds)
            }
        }
        Task { await prefetchAllCovers() }
    }

    /// Silently refreshes only the progress data (bars, "Continue"), without
    /// reloading the whole book list or showing a spinner. Called e.g. when the
    /// app returns to the foreground.
    func refreshProgress() async {
        guard !cachedItems.isEmpty, !loadInFlight else { return }
        guard let progress = try? await provider.fetchAllProgress() else {
            // Offline/error: keep the last known state instead of wiping it.
            return
        }
        // Also refresh the item list itself (silently, no spinner): freshly
        // added books and edited metadata (e.g. series) would otherwise only
        // show up after a cold start — refreshProgress used to rebuild from
        // the stale cached items.
        var items = cachedItems
        if let libraryId, let fresh = try? await provider.fetchLibraryItems(libraryId: libraryId) {
            items = fresh
        }
        isShowingOfflineCache = false
        await rebuild(items: items, progress: progress)
        saveLibraryDiskCache(items: items, progress: progress)
    }

    /// Re-mix the list after importing/deleting local files — without querying
    /// the server again (uses the already-loaded server items).
    func refreshAfterLocalChange() async {
        await reloadLocalCache()
        // Offline/error: keep the last known progress — `?? [:]` used to blank
        // out every bar and the Continue row until the next successful load.
        let progress = (try? await provider.fetchAllProgress()) ?? lastProgress
        await rebuild(items: cachedItems, progress: progress)
    }

    /// A server item + (server/local) progress + queued updates → a
    /// display-ready `LibraryEntry`. Extracted so both the full list and the
    /// seed rows (Continue/Recently Added) are prepared exactly the same way.
    nonisolated private static func makeEntry(item: LibraryItem,
                                              progress: [String: BookProgress],
                                              queued: [String: SyncQueue.PendingUpdate]) -> LibraryEntry {
        var p = progress[item.id]
        // Multi-file fallback: if the server has no fraction (duration 0/empty
        // there) but a position, recompute it from the LOCALLY known book
        // duration — otherwise bars/"Continue" are missing.
        if let existing = p, existing.fraction <= 0.001, !existing.isFinished,
           let time = existing.currentTime, time > 0,
           let duration = item.media?.duration, duration > 0 {
            p = BookProgress(
                fraction: min(max(time / duration, 0), 1),
                isFinished: existing.isFinished,
                lastUpdate: existing.lastUpdate,
                currentTime: time
            )
        }
        // Layer not-yet-sent (queued) updates OVER the server state — otherwise
        // the library shows the old state until the flush, which looks like
        // progress loss.
        if let q = queued[item.id] {
            let duration = q.duration > 0 ? q.duration : (item.media?.duration ?? 0)
            p = BookProgress(
                fraction: duration > 0 ? min(max(q.currentTime / duration, 0), 1) : (p?.fraction ?? 0),
                isFinished: q.isFinished,
                lastUpdate: q.queuedAt ?? p?.lastUpdate ?? 0,
                currentTime: q.currentTime
            )
        }
        return LibraryEntry(item: item, progress: p)
    }

    /// Progress used by the last rebuild — the fallback when a silent refresh
    /// can't reach the server (otherwise all bars/Continue would blank out).
    private var lastProgress: [String: BookProgress] = [:]

    /// Everything the off-main rebuild computation needs, as a value snapshot.
    nonisolated struct RebuildInput: Sendable {
        let items: [LibraryItem]
        let progress: [String: BookProgress]
        let queued: [String: SyncQueue.PendingUpdate]
        let localCache: [LibraryEntry]
        let seedContinue: [LibraryItem]
        let seedRecent: [LibraryItem]
        let sort: SortOption
        let ascending: Bool
        let filter: FilterOption
        let downloadedIds: Set<String>
    }

    nonisolated struct RebuildOutput: Sendable {
        let entries: [LibraryEntry]
        let continueListening: [LibraryEntry]
        let recentlyAdded: [LibraryEntry]
        let sorted: [LibraryEntry]
        let grouped: [GridEntry]
    }

    /// S6: the expensive part of a rebuild — makeEntry over every item, the
    /// Continue/Recently unions and sorts, AND the memoized derived lists — runs
    /// OFF the main actor over the snapshot; the main actor only assigns.
    nonisolated static func computeRebuild(_ input: RebuildInput) -> RebuildOutput {
        let combined = input.items.map {
            makeEntry(item: $0, progress: input.progress, queued: input.queued)
        }
        // Always mix in local files (preloaded via their provider) — regardless
        // of server status, they are offline available by definition.
        let entries = combined + input.localCache

        // Continue/Recently as the union of the already-loaded pages AND the
        // server seed — so both rows are complete immediately and never get
        // shorter while loading progressively. Already-loaded entries win
        // (fresher progress).
        let byId = Dictionary(combined.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })

        var continueById: [String: LibraryEntry] = [:]
        for e in combined where e.progress?.isStarted ?? false { continueById[e.id] = e }
        for item in input.seedContinue where byId[item.id] == nil {
            let e = makeEntry(item: item, progress: input.progress, queued: input.queued)
            if e.progress?.isStarted ?? false { continueById[e.id] = e }
        }
        let continueListening = continueById.values
            .sorted { ($0.progress?.lastUpdate ?? 0) > ($1.progress?.lastUpdate ?? 0) }

        var recentById = byId
        for item in input.seedRecent where recentById[item.id] == nil {
            recentById[item.id] = makeEntry(item: item, progress: input.progress, queued: input.queued)
        }
        let recentlyAdded = recentById.values
            .sorted { ($0.item.addedAt ?? 0) > ($1.item.addedAt ?? 0) }
            .prefix(15)
            .map { $0 }

        // Pre-compute the memoized derived lists for the new state so the first
        // body evaluation after the assignment hits a warm cache.
        let sorted = sortedFiltered(entries: entries, sort: input.sort,
                                    ascending: input.ascending, filter: input.filter,
                                    downloadedIds: input.downloadedIds)
        let grouped = seriesGrouped(entries: entries, ascending: input.ascending,
                                    filter: input.filter, downloadedIds: input.downloadedIds)
        return RebuildOutput(entries: entries, continueListening: continueListening,
                             recentlyAdded: recentlyAdded, sorted: sorted, grouped: grouped)
    }

    /// Coalescing: while one off-main rebuild runs, later calls just replace the
    /// pending snapshot (merge to latest) instead of queuing up.
    private var rebuildRunning = false
    private var pendingRebuild: (items: [LibraryItem], progress: [String: BookProgress])?

    private func rebuild(items: [LibraryItem], progress: [String: BookProgress]) async {
        if rebuildRunning {
            pendingRebuild = (items, progress)
            return
        }
        rebuildRunning = true
        cachedItems = items
        lastProgress = progress
        let input = RebuildInput(
            items: items, progress: progress,
            queued: SyncQueue.shared.allPending(),
            localCache: localCache,
            seedContinue: librarySeed.continueListening,
            seedRecent: librarySeed.recentlyAdded,
            sort: sortOption, ascending: sortAscending, filter: filterOption,
            downloadedIds: DownloadManager.shared.downloadedItemIds
        )
        let output = await Task.detached(priority: .userInitiated) {
            // Regression guard: the library rebuild must stay off the main actor
            // (it used to hitch scrolling). Fires if it ever drifts back.
            #if DEBUG
            dispatchPrecondition(condition: .notOnQueue(.main))
            #endif
            return Self.computeRebuild(input)
        }.value
        entries = output.entries   // didSet bumps entriesStamp
        continueListening = output.continueListening
        recentlyAdded = output.recentlyAdded
        // Warm the memo caches (key derived AFTER the entries assignment).
        let key = derivedKey()
        sortedCacheKey = key
        sortedCache = output.sorted
        groupedCacheKey = key
        groupedCache = output.grouped
        rebuildRunning = false
        if let pending = pendingRebuild {
            pendingRebuild = nil
            await rebuild(items: pending.items, progress: pending.progress)
        }
    }

    /// Query the local source ONLY via its provider (items + progress) — the
    /// core knows neither LocalLibrary nor the `local:` prefix. Called at the
    /// start of every load (in-memory, never an error).
    private func reloadLocalCache() async {
        let localProvider = AppSession.shared.localProvider
        let items = (try? await localProvider.fetchLibraryItems(libraryId: "local")) ?? []
        let progress = (try? await localProvider.fetchAllProgress()) ?? [:]
        localCache = items.map { LibraryEntry(item: $0, progress: progress[$0.id]) }
    }

    private func saveLibraryDiskCache(items: [LibraryItem], progress: [String: BookProgress]) {
        // Only write if something actually changed — otherwise every
        // reload/refreshProgress writes the same JSON to disk again. Cheap
        // signature from ids+addedAt (items) and keys+lastUpdate (progress).
        var hasher = Hasher()
        hasher.combine(items.count)
        for item in items { hasher.combine(item.id); hasher.combine(item.addedAt ?? 0) }
        for (key, p) in progress.sorted(by: { $0.key < $1.key }) {
            hasher.combine(key); hasher.combine(p.lastUpdate); hasher.combine(p.isFinished)
        }
        let signature = hasher.finalize()
        guard signature != lastSavedSignature else { return }
        lastSavedSignature = signature

        // Encode + write off the main thread: with large libraries this is a
        // visible hitch right when the refresh spinner settles.
        let cache = LibraryDiskCache(items: items, progress: progress)
        let url = diskCacheURL
        Task.detached(priority: .utility) {
            guard let data = try? JSONEncoder().encode(cache) else { return }
            try? data.write(to: url, options: .atomic)
        }
    }

    /// Full-library decode off-main — on an offline cold start this is the
    /// whole library JSON and would otherwise block the main actor.
    private func loadDiskCache() async -> LibraryDiskCache? {
        let url = diskCacheURL
        return await Task.detached(priority: .userInitiated) {
            guard let data = try? Data(contentsOf: url) else { return nil }
            return try? JSONDecoder().decode(LibraryDiskCache.self, from: data)
        }.value
    }

    /// Prefetches only the RELEVANT covers in the background (sequentially, easy
    /// on the often internet-reached server): the top rows (Continue, Recently)
    /// plus the first visible entries of the list. The rest loads lazily on
    /// scroll via `CachedAsyncImage` — this saves hundreds of unnecessary
    /// requests with large libraries. Already-cached covers are skipped (see
    /// `ImageCache.preload`), so repeats are cheap.
    private func prefetchAllCovers() async {
        var ids: [String] = []
        var seen = Set<String>()
        func add(_ id: String) { if seen.insert(id).inserted { ids.append(id) } }
        for e in continueListening { add(e.id) }
        for e in recentlyAdded { add(e.id) }
        for item in cachedItems.prefix(40) { add(item.id) }

        for id in ids {
            guard let url = provider.coverURL(forItemId: id) else { continue }
            await ImageCache.shared.preload(url)
        }
    }
}
