// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

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
        didSet {
            entriesStamp &+= 1
            // TF4/E2: rebuild the id index so per-tile lookups stay O(1).
            entriesById = Self.indexById(entries)
        }
    }

    /// TF4/E2 (pure, tested): id → entry index; on a duplicate id the first
    /// entry wins (mirrors `first(where:)`, whose result it replaces).
    nonisolated static func indexById(_ entries: [LibraryEntry]) -> [String: LibraryEntry] {
        Dictionary(entries.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }
    /// TF4/E2: id → entry index. Home tiles and series navigation resolved an
    /// entry with `entries.first(where:)` — O(N) per tile per render, which on
    /// the Home page (many tiles, frequent redraws) was a needless cost. The
    /// index is rebuilt only when `entries` changes. Not @Published: it is
    /// derived from `entries`, whose own change already drives the views.
    private(set) var entriesById: [String: LibraryEntry] = [:]

    /// O(1) resolve of a loaded entry by id. The shelves are not indexed — use
    /// `libraryItem(forId:)` when a shelf-only item must resolve too.
    func entry(id: String) -> LibraryEntry? { entriesById[id] }
    @Published var continueListening: [LibraryEntry] = []
    /// Every started title, unfiltered by the Continue age cutoff — the source
    /// Rediscover pulls its "paused" candidates from (see RebuildOutput).
    @Published var continueAll: [LibraryEntry] = []
    @Published var recentlyAdded: [LibraryEntry] = []
    @Published var isLoading = false
    @Published var errorMessage: String?
    /// True while the cached offline library is being shown because the server
    /// was unreachable — for a subtle UI hint instead of a hard error.
    @Published var isShowingOfflineCache = false
    /// True while further pages are still loading progressively after the first
    /// (immediately visible) page — drives the "Loading more…" footer.
    @Published var isLoadingMore = false

    /// T3/T5: resolve a loaded audiobook/local item by id — for the global
    /// Up-Next queue (render + cross-media auto-continue) and session restore.
    /// The shelves are checked too, so an item that is only on a shelf still
    /// resolves before the full grid has paged in.
    func libraryItem(forId itemId: String) -> LibraryItem? {
        // E2: the big `entries` list resolves via the O(1) index; the two small
        // shelves stay a linear scan (an item only there still resolves).
        if let hit = entriesById[itemId] { return hit.item }
        for list in [continueListening, recentlyAdded] {
            if let hit = list.first(where: { $0.id == itemId }) { return hit.item }
        }
        return nil
    }

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
    var authorGroups: [(name: String, entries: [LibraryEntry])] { Self.authorGroups(of: entries) }

    /// Books grouped by genre — a book can appear in several genres.
    var genreGroups: [(name: String, entries: [LibraryEntry])] { Self.genreGroups(of: entries) }

    /// Pure grouping cores (Such-Freeze (a) 01.08): static so the search deck
    /// can compute them OFF the main thread — the full-stock grouping + ICU
    /// sorts froze the first search open when run per body eval.
    nonisolated static func authorGroups(of entries: [LibraryEntry]) -> [(name: String, entries: [LibraryEntry])] {
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

    nonisolated static func genreGroups(of entries: [LibraryEntry]) -> [(name: String, entries: [LibraryEntry])] {
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
    /// F3 (pure, tested): the author-portrait tap filters the library only
    /// when the author has MORE than one work here; a single work stays a
    /// plain image without a tap.
    nonisolated static func authorFilterEnabled(workCount: Int) -> Bool {
        workCount > 1
    }

    func nextInSeries(after itemId: String) -> LibraryEntry? {
        guard let current = entry(id: itemId),
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
        // The LOCAL sources come first, and they come UNCONDITIONALLY. They
        // used to sit behind the server guard below, so a start without an
        // Audiobookshelf login collected nothing at all — imported files and a
        // Subsonic set to audiobooks were present, available, and never asked.
        // In the same session after an import everything looked right; only
        // the next launch showed the empty library, which is why it survived
        // this long.
        await reloadLocalCache()
        // F10: no signed-in book source (serverless start) — no server load,
        // and no fake offline/error state on the aggregation surfaces. What is
        // local still has to reach the list, so the rebuild runs.
        guard provider.isAvailable else {
            await rebuild(items: [], progress: [:])
            return
        }
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
        // Befund M ("kein Spinner ohne Endzustand"): a BACKGROUND refresh with
        // stock on screen must end promptly when the server is away — the
        // retry tower (3 attempts x ~20 s connect timeout, several call
        // sites) kept `isRefreshing` (= the floating activity pill over the
        // Continue cards) spinning for minutes on 5G where the mesh-only
        // server is unreachable. With a cache showing, ONE attempt per call
        // is honest: fail fast -> silent cache state (the card keeps working,
        // resume is offline-capable). First installs (nothing on screen)
        // keep the full retry patience.
        let retryAttempts = entries.isEmpty ? 3 : 1
        let refreshStarted = Date()
        defer {
            // Diagnostic (keep): if the pill class reappears at GT, this line
            // names the actual duration instead of a guess.
            let elapsed = Date().timeIntervalSince(refreshStarted)
            if elapsed > 30 {
                Logger.library.notice("REFRESH long run: \(Int(elapsed))s with stock=\(self.entries.count)")
            }
        }
        do {
            // K2 — skip the first serial round-trip: with a stored library id,
            // start progress/seed/first page immediately and only VALIDATE the
            // library list in parallel. If the stored library vanished, fall
            // back to today's resolve-then-load behavior.
            let storedId = UserDefaults.standard.string(forKey: AppStorageKeys.selectedLibraryId)
            if let storedId {
                async let validationTask: [ABSLibrary]? = try? await withRetry(attempts: retryAttempts) {
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
                let libraries = try await withRetry(attempts: retryAttempts) { try await self.provider.fetchLibraries() }
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

    /// F6: the last library id that actually loaded — the search endpoint's
    /// fallback when no explicit settings choice is stored.
    static var lastKnownLibraryId: String?

    /// Full progressive content load of one library: progress + seed in
    /// parallel, first page immediately, remaining pages quietly, disk cache and
    /// key cleanup only when complete. Extracted so the K2 fast path (stored
    /// library id, no prior fetchLibraries round-trip) shares one implementation
    /// with the resolve path.
    private func loadContent(libraryId id: String) async throws {
        Self.lastKnownLibraryId = id
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
        // Befund M: same fail-fast rule as loadLibrary — with stock on screen
        // one attempt, full patience only on an empty first load.
        let first = try await withRetry(attempts: entries.isEmpty ? 3 : 1) {
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
    /// X16b: after a restart-from-the-beginning, clear the 'finished' flag in the
    /// LOCAL library state so the grid + detail page stop showing 'gehört'
    /// immediately (the server was already cleared via the player's progress
    /// sync). Progress resumes normally from 0.
    func markUnfinishedLocally(itemId: String) {
        let fresh = BookProgress(fraction: 0, isFinished: false,
                                 lastUpdate: Date().timeIntervalSince1970 * 1000, currentTime: 0)
        func clear(_ list: inout [LibraryEntry]) {
            if let i = list.firstIndex(where: { $0.id == itemId }),
               list[i].progress?.isFinished == true {
                list[i] = LibraryEntry(item: list[i].item, progress: fresh)
            }
        }
        clear(&entries)
        clear(&continueListening)
        clear(&continueAll)
        clear(&recentlyAdded)
    }

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
            // Plausibility (like loadContent only persisting a COMPLETE load): a
            // foreground refresh must not shrink the visible library on a partial
            // 2xx answer — and this result is even persisted to the disk cache.
            // Accept the fresh list only when it is not smaller than the cache.
            #if DEBUG
            let cachedCount = cachedItems.count
            if fresh.count < cachedCount {
                Logger.library.debug("ABS refreshProgress: fresh=\(fresh.count) < cached=\(cachedCount) → keeping cached (implausible shrink)")
            }
            #endif
            items = Self.plausibleFreshItems(fresh, cached: cachedItems)
        }
        isShowingOfflineCache = false
        await rebuild(items: items, progress: progress)
        saveLibraryDiskCache(items: items, progress: progress)
    }

    /// ABS hardening (pure, tested): accept a silent foreground re-fetch only
    /// when it is not SMALLER than the cache — a partial/hiccuped answer must not
    /// shrink (and then persist) the visible library. Real growth is taken as is.
    /// (A genuine server-side deletion needs an explicit path, not a quiet
    /// foreground shrink — flagged for a decision, not given a back door here.)
    nonisolated static func plausibleFreshItems(_ fresh: [LibraryItem], cached: [LibraryItem]) -> [LibraryItem] {
        fresh.count >= cached.count ? fresh : cached
    }

    /// Re-mix the list after importing/deleting local files — without querying
    /// the server again (uses the already-loaded server items).
    /// df0b3bb 3: a title was taken off (or returned to) the Continue rows.
    /// Purely local — rebuild from what is already loaded, no server round trip
    /// for a decision the user just made on this device.
    func refreshContinueRows() async {
        await rebuild(items: cachedItems, progress: lastProgress)
    }

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
    nonisolated static func makeEntry(item: LibraryItem,
                                      progress: [String: BookProgress],
                                      queued: [String: SyncQueue.PendingUpdate]) -> LibraryEntry {
        var p = progress[item.id]
        // TF1: for MULTI-FILE books the client deliberately sends no server
        // `progress`/`duration` (an explicit 0 would clobber existing server
        // progress) — so the server fraction FREEZES while `currentTime` keeps
        // advancing. The authoritative value is `currentTime` over the LOCALLY
        // known total duration. Recompute it whenever both are known and the
        // book is not finished — previously this only ran for a ~0 server
        // fraction, so a frozen non-zero fraction (e.g. 0.10) was shown stale.
        // Non-regression: single-file books have currentTime/duration equal to
        // the server fraction (unchanged); `isFinished` is preserved (no
        // un-finish); no local duration → keep the server fraction (not 0).
        if let existing = p, !existing.isFinished,
           let time = existing.currentTime, time > 0,
           let duration = item.media?.duration, duration > 0 {
            let recomputed = min(max(time / duration, 0), 1)
            #if DEBUG
            if abs(existing.fraction - recomputed) > 0.02 {
                Logger.library.log("TF1 progress \(item.id, privacy: .public): server=\(existing.fraction) currentTime=\(time) duration=\(duration) → \(recomputed)")
            }
            #endif
            p = BookProgress(
                fraction: recomputed,
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
    /// 96cb043/2100b09: started titles outside the server library — resolved
    /// HERE because the item lookup is main-actor bound, then handed to the
    /// off-main rebuild as plain data.
    @MainActor
    static func continueExtras() -> [LibraryEntry] {
        ContinueSources.started(in: UserDefaults.standard.dictionaryRepresentation(),
                                serverKnows: [])
            .compactMap { extra in
                guard let item = AppSession.shared.playableItem(forId: extra.id) else { return nil }
                // `isStarted` reads the FRACTION, so it needs a duration —
                // with one from the mark it is exact, without one the entry
                // counts as barely started instead of silently dropping out.
                let fraction = extra.duration > 0
                    ? min(max(extra.position / extra.duration, 0), 1) : 0.01
                return LibraryEntry(
                    item: item,
                    progress: BookProgress(fraction: fraction, isFinished: false,
                                           lastUpdate: extra.updatedAtMs,
                                           currentTime: extra.position))
            }
    }

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
        /// df0b3bb 3: per-item "not under Continue any more" markers.
        var hiddenMarkers: [String: Double] = [:]
        /// 96cb043/2100b09: started titles OUTSIDE the server library —
        /// local sideloads and catalog works, resolved by the caller (their
        /// item lookup is main-actor bound).
        var continueExtras: [LibraryEntry] = []
    }

    nonisolated struct RebuildOutput: Sendable {
        let entries: [LibraryEntry]
        let continueListening: [LibraryEntry]
        /// EVERY started title, including the ones the age cutoff removes from
        /// the row above. Rediscover's "paused" source feeds from this — it
        /// draws exactly the entries Continue drops, so the cutoff MOVES a
        /// title from one row to the other instead of erasing it from both.
        let continueAll: [LibraryEntry]
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
        // 305a292: ask the won source, not the raw one — a frozen cached zero
        // must not delete a book from the row it belongs in.
        let defaults = UserDefaults.standard
        func started(_ e: LibraryEntry) -> Bool {
            ContinueSources.isStarted(
                serverSaysStarted: e.progress?.isStarted ?? false,
                flushed: ListeningStore.flushed(e.id, in: defaults))
        }
        for e in combined where started(e) { continueById[e.id] = e }
        for item in input.seedContinue where byId[item.id] == nil {
            let e = makeEntry(item: item, progress: input.progress, queued: input.queued)
            if started(e) { continueById[e.id] = e }
        }
        // df0b3bb: two things were missing here, and their absence was not a
        // concept — `recentlyAdded` two lines below has had a cap all along.
        // (1) AGE: what has lain untouched for longer is not "continue" any
        //     more, it is a case for Rediscover — which owns that mechanic
        //     including the threshold. Same constant reused, no second one
        //     invented, so a title cannot sit in both rows at once.
        // (2) CAP: a row is the preview of a page (3a3b1aa); the complete
        //     stock belongs behind the chevron.
        // 96cb043/2100b09: the row takes the OTHER classes too — locally
        // sideloaded books and catalog works keep their position in the same
        // second-backup, and both were structurally invisible here (the row
        // only knew the source it was born from). One collection, so the
        // next class plugs in instead of being forgotten again.
        // Dedupe: the SERVER identity leads — a downloaded ABS book stays one
        // entry, local sideloads are their own identity.
        for extra in input.continueExtras where byId[extra.id] == nil && continueById[extra.id] == nil {
            continueById[extra.id] = extra
        }
        let continueAll = continueById.values
            .sorted { ($0.progress?.lastUpdate ?? 0) > ($1.progress?.lastUpdate ?? 0) }
        // The AGE CUTOFF is GONE.
        // Continue is the row of ALL started books again — a book left lying
        // for four weeks is exactly what he wants to continue, not "gone from
        // Continue". The e46e7b4 cutoff was my design decision inside
        // df0b3bb/6fcb301; it hollowed out a visible surface nobody ordered
        // hollowed. Lesson (into the report): capping (display) and culling
        // (stock) are two different operations — df0b3bb ordered the first,
        // I also built the second.
        // C2: Rediscover keeps feeding from continueAll with its own
        // threshold — the overlap is WANTED (one row answers "what did I
        // start?", the other "what did I forget?").
        // The manual hide gesture (ContinueHidden) stays untouched.
        let continueListening = continueAll
            .filter { entry in
                !ContinueHidden.isHidden(id: entry.id,
                                         lastUpdate: entry.progress?.lastUpdate ?? 0,
                                         markers: input.hiddenMarkers)
            }

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
                             continueAll: continueAll,
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
            downloadedIds: DownloadManager.shared.downloadedItemIds,
            hiddenMarkers: ContinueHiddenStore.markers(),
            continueExtras: Self.continueExtras()
        )
        let output = await Task.detached(priority: .userInitiated) {
            // Regression guard: the library rebuild must stay off the main actor
            // (it used to hitch scrolling). Fires if it ever drifts back.
            #if DEBUG
            dispatchPrecondition(condition: .notOnQueue(.main))
            #endif
            return Self.computeRebuild(input)
        }.value
        // Layout-shift fix: a progressive page landing mid-scroll used to grow
        // the grid under the finger — non-initial applies wait for the shared
        // calm gate (BottomBarState). The initial fill (empty library) applies
        // immediately; queued applies flush in order, so the newest state wins.
        let applyOutput: @MainActor () -> Void = { [self] in
            entries = output.entries   // didSet bumps entriesStamp
            continueListening = output.continueListening
            continueAll = output.continueAll
            recentlyAdded = output.recentlyAdded
            // Warm the memo caches (key derived AFTER the entries assignment).
            let key = derivedKey()
            sortedCacheKey = key
            sortedCache = output.sorted
            groupedCacheKey = key
            groupedCache = output.grouped
        }
        if entries.isEmpty {
            applyOutput()
        } else {
            BottomBarState.shared.runWhenCalm(applyOutput)
        }
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
        // Generalized (Booksonic): EVERY secondary audiobook-typed source
        // merges here via its provider — local files and a Subsonic source the
        // user set to audiobooks. The core still knows no concrete provider
        // and no id namespace; the main (ABS) provider stays the primary path.
        let session = AppSession.shared
        var entries: [LibraryEntry] = []
        for provider in session.allProviders
        where provider !== session.provider && provider.mediaType == .audiobooks && provider.isAvailable {
            let items = (try? await provider.fetchLibraryItems(libraryId: provider.providerId)) ?? []
            let progress = (try? await provider.fetchAllProgress()) ?? [:]
            entries += items.map { LibraryEntry(item: $0, progress: progress[$0.id]) }
        }
        localCache = entries
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
