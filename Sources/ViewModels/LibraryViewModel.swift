// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation
import Combine
import OSLog

/// A book with (optional) progress. The unit the views display.
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

    /// Display name (localized). The rawValue stays the stable persistence key.
    var label: String {
        switch self {
        case .titel: return String(localized: "Title")
        case .autor: return String(localized: "Author")
        case .serie: return String(localized: "Series")
        case .zuletztHinzugefuegt: return String(localized: "Recently Added")
        case .zuletztGehoert: return String(localized: "Recently Listened")
        }
    }

    /// Sensible default direction per sort type. Title/author/series
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

    /// Display name (localized). The rawValue stays the stable persistence key.
    var label: String {
        switch self {
        case .alle: return String(localized: "All")
        case .unfertig: return String(localized: "Unfinished")
        case .fertig: return String(localized: "Finished")
        case .heruntergeladen: return String(localized: "Downloaded")
        }
    }
}

/// Persistent library cache. The reason the book list still shows even fully
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
            // Rebuild the id index so per-tile lookups stay O(1).
            entriesById = Self.indexById(entries)
        }
    }

    /// Pure and tested: id → entry index; on a duplicate id the first
    /// entry wins (mirrors `first(where:)`, whose result it replaces).
    nonisolated static func indexById(_ entries: [LibraryEntry]) -> [String: LibraryEntry] {
        Dictionary(entries.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }
    /// Id → entry index. Home tiles and series navigation resolved an
    /// entry with `entries.first(where:)`. O(N) per tile per render, which on
    /// the Home page (many tiles, frequent redraws) was a needless cost. The
    /// index is rebuilt only when `entries` changes. Not @Published: it is
    /// derived from `entries`, whose own change already drives the views.
    private(set) var entriesById: [String: LibraryEntry] = [:]

    /// O(1) resolve of a loaded entry by id. The shelves are not indexed. Use
    /// `libraryItem(forId:)` when a shelf-only item must resolve too.
    func entry(id: String) -> LibraryEntry? { entriesById[id] }
    @Published var continueListening: [LibraryEntry] = []
    /// Every started title, unfiltered by the Continue age cutoff. The source
    /// Rediscover pulls its "paused" candidates from (see RebuildOutput).
    @Published var continueAll: [LibraryEntry] = []
    @Published var recentlyAdded: [LibraryEntry] = []
    @Published var isLoading = false
    @Published var errorMessage: String?
    /// True while the cached offline library is being shown because the server
    /// was unreachable. For a subtle UI hint instead of a hard error.
    @Published var isShowingOfflineCache = false
    /// True while further pages are still loading progressively after the first
    /// (immediately visible) page. Drives the "Loading more…" footer.
    @Published var isLoadingMore = false

    /// Resolve a loaded audiobook/local item by id. For the global
    /// Up-Next queue (render + cross-media auto-continue) and session restore.
    /// The shelves are checked too, so an item that is only on a shelf still
    /// resolves before the full grid has paged in.
    func libraryItem(forId itemId: String) -> LibraryItem? {
        shelvedEntry(id: itemId)?.item
    }

    /// The entry with its progress, from the grid or a shelf. The book page
    /// asks this: a title only on a shelf has its page before the grid
    /// has paged in.
    func shelvedEntry(id itemId: String) -> LibraryEntry? {
        // The big `entries` list resolves via the O(1) index; the two small
        // shelves stay a linear scan (an item only there still resolves).
        if let hit = entriesById[itemId] { return hit }
        for list in [continueListening, recentlyAdded] {
            if let hit = list.first(where: { $0.id == itemId }) { return hit }
        }
        return nil
    }

    /// Sort/filter are remembered in UserDefaults. So they persist across app
    /// restarts. When the user changes the sort type, the direction jumps to its
    /// sensible default (see `SortOption.defaultAscending`); the direction itself
    /// can then be flipped via the menu toggle and stays until the next sort-type
    /// change.
    @Published var sortOption: SortOption {
        didSet {
            AppStorageKeys.set(sortOption.rawValue, for: Keys.sortOption)
            UserChoiceCloudSync.shared.noteScalar(key: Keys.sortOption, value: sortOption.rawValue)
            sortAscending = sortOption.defaultAscending
        }
    }
    @Published var filterOption: FilterOption {
        didSet {
            AppStorageKeys.set(filterOption.rawValue, for: Keys.filterOption)
            UserChoiceCloudSync.shared.noteScalar(key: Keys.filterOption, value: filterOption.rawValue)
        }
    }
    @Published var sortAscending: Bool {
        didSet {
            AppStorageKeys.set(sortAscending, for: Keys.sortAscending)
            UserChoiceCloudSync.shared.noteScalar(key: Keys.sortAscending, value: sortAscending)
        }
    }

    @objc private nonisolated func choicesAdopted(_ note: Notification) {
        let adopted = note.userInfo?["keys"] as? [String] ?? []
        guard !adopted.isEmpty else { return }
        Task { @MainActor in
            guard adopted.contains(where: { [Keys.sortOption, Keys.sortAscending,
                                             Keys.filterOption].contains($0) }) else { return }
            self.adoptTravelledSortState()
        }
    }

    /// Choice-family adoption: re-read the travelled values. Order matters.
    /// Assigning `sortOption` cascades a default onto `sortAscending`, so the
    /// direction is applied AFTER the sort kind, never clobbered by it. The
    /// derived lists recompute on their own (the memo key carries all three).
    func adoptTravelledSortState() {
        if let raw = AppStorageKeys.string(Keys.sortOption),
           let option = SortOption(rawValue: raw), option != sortOption {
            sortOption = option
        }
        if AppStorageKeys.exists(Keys.sortAscending),
           AppStorageKeys.bool(Keys.sortAscending) != sortAscending {
            sortAscending = AppStorageKeys.bool(Keys.sortAscending)
        }
        if let raw = AppStorageKeys.string(Keys.filterOption),
           let option = FilterOption(rawValue: raw), option != filterOption {
            filterOption = option
        }
    }

    private enum Keys {
        static let sortOption = AppStorageKeys.librarySortOption
        static let filterOption = AppStorageKeys.libraryFilterOption
        static let sortAscending = AppStorageKeys.librarySortAscending
    }

    private let provider: any AudioProvider
    private var cachedItems: [LibraryItem] = []
    private var libraryId: String?
    /// Server-prebuilt "Continue"/"Recently Added" rows. Merged in `rebuild`
    /// with the already-loaded pages so the top rows are complete immediately and
    /// never get shorter while loading.
    private var librarySeed = LibrarySeed()
    /// Signature of the last written disk cache. Avoids redundant JSON writes
    /// when items/progress have not changed.
    private var lastSavedSignature: Int?
    /// Entries last loaded via the local provider. Cached so `rebuild`
    /// (synchronous, many callers) can append them without another async fetch.
    /// Updated in loadLibrary/refresh (always via the provider, never directly
    /// via LocalLibrary. Otherwise it gets messy).
    private var localCache: [LibraryEntry] = []
    /// The set of sources that fed the shelf when it was last mixed. The
    /// comparison that tells a real change from an announcement.
    private var secondarySignature = ""

    /// The row backend of the cache.
    private let database: MaerDatabase
    /// The one opening of the rows: every caller awaits the same task.
    private var rowsOpening: Task<LibraryRowStore?, Never>?
    /// The rows' one write chain (`RowChain`): what they hold as far as
    /// this run knows, the mark of a start read that failed as a whole, and
    /// the serial writes. Over rows the start could not read, a write reads
    /// them first, so the diff knows what stands there; adopted is nothing
    /// of them: the rows are an image of the servers and this run's fetch is
    /// the newer image.
    private let rowChain: RowChain<LibraryDiskCache> = {
        let chain = RowChain<LibraryDiskCache>(label: "LIBROWS")
        chain.adopt = { _ in }
        return chain
    }()
    /// The cache the last save handed over, taken by the write when it runs.
    private var cacheToWrite: LibraryDiskCache?

    init(
        provider: any AudioProvider,
        database: MaerDatabase = .shared
    ) {
        self.provider = provider
        self.database = database

        // Important: keep `resolvedSortOption` as a local variable, don't read it
        // back via `self.sortOption`. Swift forbids any access via self on
        // classes before ALL stored properties (here: also the later
        // sortAscending) have a value.
        let resolvedSortOption: SortOption
        if let raw = AppStorageKeys.string(Keys.sortOption), let option = SortOption(rawValue: raw) {
            resolvedSortOption = option
        } else {
            resolvedSortOption = .titel
        }
        sortOption = resolvedSortOption

        if let raw = AppStorageKeys.string(Keys.filterOption), let option = FilterOption(rawValue: raw) {
            filterOption = option
        } else {
            filterOption = .alle
        }
        if AppStorageKeys.exists(Keys.sortAscending) {
            sortAscending = AppStorageKeys.bool(Keys.sortAscending)
        } else {
            sortAscending = resolvedSortOption.defaultAscending
        }
        NotificationCenter.default.addObserver(
            self, selector: #selector(choicesAdopted),
            name: .userChoicesAdopted, object: nil)
        // The Continue rows follow every listening event (a local start, a
        // pause, a takeover) at once: a local rebuild from what is loaded,
        // with the queued position layered over the server state. No
        // network, and the rebuild never bumps the revision, so no loop.
        revisionCancellable = ListeningRevision.shared.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                Task { @MainActor in
                    // Nothing loaded yet (cold start, or a seeded harness
                    // that fills the lists directly): a rebuild from an
                    // empty cache would blank them.
                    guard let self, !self.cachedItems.isEmpty else { return }
                    await self.refreshContinueRows()
                }
            }
    }

    private var revisionCancellable: AnyCancellable?

    // MARK: - Memoized derived lists

    /// The sorted/grouped lists below are read from `body`. And the body can be
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
    /// Cache key for `downloadedEntries`. Only the library revision and
    /// the downloaded-set identity affect it. Without this the Downloaded
    /// section filtered+sorted the WHOLE library on every render/section mount
    /// (LibraryView observes DownloadManager, so it re-renders often). An
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

    /// Pure sorting/filtering core. Nonisolated so the off-main rebuild
    /// can pre-compute it over a snapshot.
    nonisolated static func sortedFiltered(
        entries: [LibraryEntry], sort: SortOption, ascending: Bool,
        filter: FilterOption, downloadedIds: Set<String>
    ) -> [LibraryEntry] {
        let filtered = entries.filter { matchesFilter($0, filter: filter, downloadedIds: downloadedIds) }

        // Each case deliberately returns the ASCENDING order. The direction is
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
    /// are offline-available by definition. Mirrors
    /// `DownloadManager.isDownloaded` without touching main-actor state.
    nonisolated private static func matchesFilter(
        _ entry: LibraryEntry, filter: FilterOption, downloadedIds: Set<String>
    ) -> Bool {
        switch filter {
        case .alle: return true
        case .unfertig: return !(entry.progress?.countsAsFinished ?? false)
        case .fertig: return entry.progress?.countsAsFinished ?? false
        case .heruntergeladen:
            return ItemNamespace.isLocal(entry.id) || downloadedIds.contains(entry.id)
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

    /// ABS series names carry the sequence in the name ("Series #2").
    /// Only the series name before it matters for grouping. Handles the
    /// known ABS quirks:
    /// - multiple series are comma-joined ("A #2, B #7") → use the FIRST
    /// - sequences can be ranges/dotted ("#1-3", "#2.5")
    /// - empty/whitespace names count as "no series"
    nonisolated static func baseSeriesName(_ raw: String?) -> String? {
        guard var name = raw?.trimmingCharacters(in: .whitespaces), !name.isEmpty else { return nil }
        // Multi-series: only segments that carry their own "#…" marker are
        // treated as separate series. A plain comma inside ONE series name
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
    /// The page of one series asks the same key, so it holds every book
    /// its group counted.
    nonisolated static func seriesGroupKey(_ base: String) -> String {
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

    /// Internal (not private). See `computeSortedFilteredEntries`.
    func computeSeriesGroupedEntries() -> [GridEntry] {
        Self.seriesGrouped(entries: entries, ascending: sortAscending, filter: filterOption,
                           downloadedIds: DownloadManager.shared.downloadedItemIds)
    }

    /// Pure series-grouping core. Nonisolated for the off-main rebuild.
    nonisolated static func seriesGrouped(
        entries: [LibraryEntry], ascending: Bool,
        filter: FilterOption, downloadedIds: Set<String>
    ) -> [GridEntry] {
        var result: [GridEntry] = []
        var indexByName: [String: Int] = [:]
        // Group from the UNFILTERED (but series-sorted) list so stacks always
        // stay complete. A partially filtered stack reads like missing books.
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
        // Single-book series render as a normal book; then apply the
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

    /// Books grouped by author, alphabetically. For browsing.
    var authorGroups: [(name: String, entries: [LibraryEntry])] { Self.authorGroups(of: entries) }

    /// Books grouped by genre. A book can appear in several genres.
    var genreGroups: [(name: String, entries: [LibraryEntry])] { Self.genreGroups(of: entries) }

    /// Pure grouping cores (Such-Freeze (a) 01.08): static so the search deck
    /// can compute them OFF the main thread. The full-stock grouping + ICU
    /// sorts froze the first search open when run per body eval.
    nonisolated static func authorGroups(of entries: [LibraryEntry]) -> [(name: String, entries: [LibraryEntry])] {
        var dict: [String: [LibraryEntry]] = [:]
        for entry in entries {
            dict[authorGroupName(of: entry), default: []].append(entry)
        }
        return dict
            .map { (name: $0.key, entries: $0.value.sorted {
                $0.item.title.localizedCaseInsensitiveCompare($1.item.title) == .orderedAscending
            }) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// The author group a book stands in: its whole author field, or the
    /// group of the books without one.
    nonisolated static func authorGroupName(of entry: LibraryEntry) -> String {
        entry.item.author ?? String(localized: "Unknown Author")
    }

    /// Books grouped by series (`baseSeriesName`, key-folded), sorted by
    /// name. A book without a series stands in none.
    nonisolated static func seriesGroups(of entries: [LibraryEntry]) -> [(name: String, entries: [LibraryEntry])] {
        var indexByKey: [String: Int] = [:]
        var groups: [(name: String, entries: [LibraryEntry])] = []
        for entry in entries {
            guard let name = baseSeriesName(entry.item.media?.metadata?.seriesName) else { continue }
            let key = seriesGroupKey(name)
            if let index = indexByKey[key] {
                groups[index].entries.append(entry)
            } else {
                indexByKey[key] = groups.count
                groups.append((name: name, entries: [entry]))
            }
        }
        return groups.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// The groups of one kind: the ONE place the books tab's page and the
    /// search deck ask.
    nonisolated static func groups(_ kind: BookGroupKind, of entries: [LibraryEntry]) -> [(name: String, entries: [LibraryEntry])] {
        switch kind {
        case .authors: return authorGroups(of: entries)
        case .series: return seriesGroups(of: entries)
        case .genres: return genreGroups(of: entries)
        }
    }

    /// The books of one group, the list its page shows: a series by the
    /// folded key its group counted under, a genre by name, an author by
    /// its group and by `AuthorMatch`, the question a typed hit asks too (so
    /// the page of an author also holds the books it wrote with others, and
    /// the group of the books without an author holds them).
    nonisolated static func books(of kind: BookGroupKind, named name: String,
                                  in entries: [LibraryEntry]) -> [LibraryEntry] {
        switch kind {
        case .authors:
            return entries.filter { authorGroupName(of: $0) == name || AuthorMatch.field($0.item.author, names: name) }
        case .series:
            let key = seriesGroupKey(name)
            return entries.filter {
                baseSeriesName($0.item.media?.metadata?.seriesName).map(seriesGroupKey) == key
            }
        case .genres:
            return entries.filter { ($0.item.media?.metadata?.genres ?? []).contains(name) }
        }
    }

    /// The same, off the main thread: the grouping and its sorts over the
    /// whole stock are a visible stall there.
    @concurrent nonisolated static func groupsOffMain(_ kind: BookGroupKind,
                                                      of entries: [LibraryEntry]) async -> [(name: String, count: Int)] {
        groups(kind, of: entries).map { (name: $0.name, count: $0.entries.count) }
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

    /// Next unfinished book of the same series, sorted by sequence. Basis
    /// for the auto-play-next setting when a book ends. nil for standalone
    /// books, unknown items, or when the series is finished.
    /// Pure and tested: the author-portrait tap filters the library only
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
        return books.dropFirst(idx + 1).first { !($0.progress?.countsAsFinished ?? false) }
    }

    /// All downloaded books, alphabetically. Its own section for a quick
    /// overview of "what can I listen to offline right now".
    var downloadedEntries: [LibraryEntry] {
        let key = DownloadedKey(stamp: entriesStamp,
                                downloadsHash: DownloadManager.shared.downloadedItemIds.hashValue)
        if key == downloadedCacheKey { return downloadedCache }
        // Signpost the (now rare) recompute so its cost + frequency are
        // visible in Instruments. This is the main-thread work that used to run
        // on every section mount/render.
        let signpost = PerfSignpost.downloadedRecompute()
        let value = entries
            .filter { DownloadManager.shared.isDownloaded(itemId: $0.id) }
            .sorted { $0.item.title.localizedCaseInsensitiveCompare($1.item.title) == .orderedAscending }
        signpost.end()
        downloadedCacheKey = key
        downloadedCache = value
        return value
    }

    /// Guards against overlapping loads (pull-to-refresh + foreground
    /// refresh + reconnect can fire together → double rebuilds, visible hitch).
    private var loadInFlight = false
    /// A pull that arrives while a load runs must not vanish silently. It
    /// queues exactly one follow-up pass.
    private var reloadQueued = false
    /// True for the whole background reload, even with content on screen.
    /// Drives the subtle toolbar/footer indicator.
    @Published var isRefreshing = false
    /// How many loads began, counted before their first suspension: the
    /// cached render lays its disk state down only when no load of this
    /// process began until then. `loadInFlight` is set after the load's
    /// first suspension, and a load that found an empty library leaves
    /// `entries` empty, so neither tells the cached render that a fresher
    /// state is already there. A load with an available source brings its
    /// own fallback to the cache; a load without one rebuilds empty, counts
    /// all the same, and then the cached render shows nothing for the rest
    /// of the process. That is right when the source is switched off. A
    /// load while the source's access could not be read yet
    /// (`accessUnknown`, before the first unlock after a restart) does not
    /// count: the cached render may still lay its state down, and the load
    /// after the access reads replaces it.
    private var loadsBegun = 0

    #if DEBUG
    /// Test seam: awaited by a load right after it is counted, before its
    /// first suspension; a witness runs the cached render in between (a
    /// load that began before the cached render and ends after it).
    var testAfterLoadBegan: (@MainActor () async -> Void)?
    #endif

    #if DEBUG
    /// Test seam: awaited by the cached render after its last suspension
    /// and before its second look; a witness runs a load in between.
    var testBeforeCachedApply: (@MainActor () async -> Void)?
    #endif

    /// Cache-first (stale-while-revalidate): render the last persisted
    /// library state IMMEDIATELY at cold start, before any network round-trip;
    /// `loadLibrary` then replaces it silently. Deliberately the FULL cached
    /// state (no downloaded-filtering. That belongs to the offline FALLBACK)
    /// and no offline banner (showing the cache at start is not an offline
    /// condition). No-op when entries are already showing or no cache exists.
    /// The disk state lies down only when no load of this process began
    /// until then, asked after the last suspension: a load that ran inside
    /// the read, one that began before it and ends after it, and one that
    /// ran to its end before it (CarPlay at a cold start, then the phone)
    /// all built a fresher state or, with an available source, bring their
    /// own fallback, and the disk state must not lie down over it; a load
    /// without an available source leaves the library empty (`loadsBegun`).
    /// The read itself still runs: it is the start read of the rows.
    func showCachedLibraryIfAvailable() async {
        guard entries.isEmpty, !loadInFlight else { return }
        guard let cache = await loadDiskCache(), !cache.items.isEmpty else { return }
        await reloadLocalCache()
        #if DEBUG
        await testBeforeCachedApply?()
        #endif
        guard loadsBegun == 0, entries.isEmpty, !loadInFlight else {
            Logger.library.notice("LIBRARY cached render skipped: a load of this run began loads=\(self.loadsBegun)")
            return
        }
        isShowingOfflineCache = false
        await rebuild(items: cache.items, progress: cache.progress)
    }

    func loadLibrary() async {
        if !provider.accessUnknown { loadsBegun += 1 }
        #if DEBUG
        await testAfterLoadBegan?()
        #endif
        // The LOCAL sources come first, and they come UNCONDITIONALLY. They
        // used to sit behind the server guard below, so a start without an
        // Audiobookshelf login collected nothing at all. Imported files and a
        // Subsonic set to audiobooks were present, available, and never asked.
        // In the same session after an import everything looked right; only
        // the next launch showed the empty library, which is why it survived
        // this long.
        await reloadLocalCache()
        // No signed-in book source (serverless start). No server load,
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
        // no cache). With the cache-first render the network load runs silently.
        isLoading = entries.isEmpty
        errorMessage = nil
        defer { isLoading = false }
        // No spinner without an end state: a BACKGROUND refresh with stock
        // on screen ends promptly when the server is away. The
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
            // Skip the first serial round-trip: with a stored library id,
            // start progress/seed/first page immediately and only VALIDATE the
            // library list in parallel. If the stored library vanished, fall
            // back to today's resolve-then-load behavior.
            let storedId = AppStorageKeys.string(AppStorageKeys.selectedLibraryId)
            if let storedId {
                async let validationTask: [ABSLibrary]? = try? await withRetry(attempts: retryAttempts) {
                    try await self.provider.fetchLibraries()
                }.filter { !$0.isPodcast }
                do {
                    let full = try await loadContent(libraryId: storedId)
                    // Late validation: the id no longer exists → reload properly.
                    let libraries = await validationTask
                    if let libraries, !libraries.contains(where: { $0.id == storedId }) {
                        try await resolveAndLoad(libraries: libraries)
                    } else {
                        cleanUpPerBook(full: full, bookLibraries: libraries?.count)
                    }
                } catch {
                    // The direct load failed. Maybe the stored library is gone
                    // (e.g. 404). If validation can name a replacement, use it;
                    // a real offline error falls through to the cache fallback.
                    guard let libraries = await validationTask,
                          !libraries.contains(where: { $0.id == storedId }) else { throw error }
                    try await resolveAndLoad(libraries: libraries)
                }
            } else {
                // ONLY book libraries for the audiobook tab. Podcast libraries
                // belong to the podcast provider. Retry transient errors briefly
                // (timeout/5xx) before the offline/cache fallback; real offline
                // errors and 401 still throw immediately.
                let libraries = try await withRetry(attempts: retryAttempts) { try await self.provider.fetchLibraries() }
                    .filter { !$0.isPodcast }
                try await resolveAndLoad(libraries: libraries)
            }
        } catch {
            // Only treat real network unreachability as "offline". Another
            // error (e.g. server hang, broken format) must not wrongly show the
            // offline hint when there actually is a connection.
            if NetworkStatus.isOfflineError(error), let cache = await loadDiskCache() {
                // Don't race the startup download scan. Playability/dimming of
                // the offline view depends on a complete downloaded set.
                await DownloadManager.shared.ensureScanned()
                isShowingOfflineCache = true
                // Offline shows the WHOLE library (last
                // cached state) + banner; titles that aren't downloaded are
                // dimmed reactively in the cells instead of being filtered out.
                await rebuild(items: cache.items, progress: cache.progress)
            } else if let cache = await loadDiskCache() {
                // Another error, but a cache exists: keep showing the last known
                // state silently, without a misleading offline hint. Including
                // clearing a leftover hint from an earlier offline load.
                isShowingOfflineCache = false
                await rebuild(items: cache.items, progress: cache.progress)
            } else {
                errorMessage = ErrorSentence.of(error)
            }
        }
    }

    /// Resolve the library (settings choice wins, else the first) and load it.
    private func resolveAndLoad(libraries: [ABSLibrary]) async throws {
        let storedId = AppStorageKeys.string(AppStorageKeys.selectedLibraryId)
        guard let library = libraries.first(where: { $0.id == storedId }) ?? libraries.first else {
            errorMessage = String(localized: "No library found on the server.")
            return
        }
        let full = try await loadContent(libraryId: library.id)
        cleanUpPerBook(full: full, bookLibraries: libraries.count)
    }

    /// The keys and rows of books that left the library go, only with a
    /// fully loaded list and only when that list is every book library of
    /// the server (`AppStorageKeys.listJudgesEveryBook`); otherwise a line
    /// and nothing goes.
    private func cleanUpPerBook(full validIds: Set<String>?, bookLibraries: Int?) {
        guard let validIds else { return }
        guard AppStorageKeys.listJudgesEveryBook(bookLibraries: bookLibraries) else {
            Logger.library.notice("CLEANUP per book skipped: book libraries=\(bookLibraries.map(String.init) ?? "unknown", privacy: .public), the list holds one")
            return
        }
        // The rows live on the main actor; their entries leave here.
        CarrierRowStores.cleanupPerBookRows(validItemIds: validIds)
        // detached because a store sweep after the load must not die with the load's task; off the MainActor
        Task.detached(priority: .utility) {
            AppStorageKeys.cleanupPerBookKeys(validItemIds: validIds)
        }
    }

    /// The last library id that actually loaded. The search endpoint's
    /// fallback when no explicit settings choice is stored.
    static var lastKnownLibraryId: String?

    /// Full progressive content load of one library: progress + seed in
    /// parallel, first page immediately, remaining pages quietly, disk cache
    /// only when complete. Extracted so the fast path (stored library id, no
    /// prior fetchLibraries round-trip) shares one implementation with the
    /// resolve path. Returns the ids of the fully loaded list, nil when the
    /// list stayed partial; the caller cleans up (`cleanUpPerBook`).
    private func loadContent(libraryId id: String) async throws -> Set<String>? {
        Self.lastKnownLibraryId = id
        async let progressTask = provider.fetchAllProgress()
        // Prebuilt "Continue"/"Recently Added" rows from the server (one small
        // request). So the top rows are complete IMMEDIATELY, regardless of
        // which page a started book is on.
        async let seedTask = provider.fetchLibrarySeed(libraryId: id)

        // Progressive loading: show the first page immediately, append the
        // rest page by page in the background. All client-side functions
        // (sort, filter, series stacks, search) work on what is already
        // loaded and complete themselves as more pages arrive.
        let pageSize = 50
        // Same fail-fast rule as loadLibrary. With stock on screen
        // one attempt, full patience only on an empty first load.
        let first = try await withRetry(attempts: entries.isEmpty ? 3 : 1) {
            try await self.provider.fetchLibraryItemsPage(libraryId: id, limit: pageSize, page: 0)
        }
        let fetchedProgress: [String: BookProgress]?
        do {
            fetchedProgress = try await progressTask
        } catch {
            Logger.library.error("LIBRARY progress failed, last known kept: \(FailureReason.of(error), privacy: .public)")
            fetchedProgress = nil
        }
        let progress = ProgressAnswer.of(fetchedProgress, known: lastProgress)
        do {
            librarySeed = try await seedTask
        } catch {
            // The start rows fall back to the pages; the line says why.
            Logger.library.notice("LIBRARY seed failed, rows from the pages: \(FailureReason.of(error), privacy: .public)")
            librarySeed = LibrarySeed()
        }

        libraryId = id
        isShowingOfflineCache = false
        var accumulated = first.items
        let total = first.total
        // Render partial pages ONLY when nothing is on screen yet (fresh install
        // / no cache). There a fast first page beats a blank wait, and the grid
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
        // 3rd page). A guaranteed final rebuild afterwards keeps the result
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

        Task { await prefetchAllCovers() }
        // Only persist and hand out ids with a FULLY loaded list. Otherwise
        // a partial list would overwrite the good offline cache, or (cleanup)
        // wrongly delete per-book keys of not-yet-loaded books.
        guard accumulated.count >= total else { return nil }
        saveLibraryDiskCache(items: accumulated, progress: progress)
        return Set(accumulated.map(\.id))
    }

    /// Silently refreshes only the progress data (bars, "Continue"), without
    /// reloading the whole book list or showing a spinner. Called e.g. when the
    /// app returns to the foreground.
    /// After a restart from the beginning, clear the 'finished' flag in the
    /// LOCAL library state so the grid + detail page stop showing 'gehört'
    /// immediately (the server was already cleared via the player's progress
    /// sync). Progress resumes normally from 0.
    func markUnfinishedLocally(itemId: String) {
        let fresh = BookProgress(fraction: 0, isFinished: false,
                                 lastUpdate: Date().timeIntervalSince1970 * 1000, currentTime: 0)
        func clear(_ list: inout [LibraryEntry]) {
            if let i = list.firstIndex(where: { $0.id == itemId }),
               list[i].progress?.countsAsFinished == true {
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
        let progress: [String: BookProgress]
        do {
            // A failure throws to the catch below and keeps the known state;
            // an answer is taken as it is (the rule's fallback has nothing to do here).
            progress = try await provider.fetchAllProgress()
        } catch {
            // Offline/error: keep the last known state instead of wiping it.
            Logger.library.notice("LIBRARY progress refresh failed, last known kept: \(FailureReason.of(error), privacy: .public)")
            return
        }
        // Also refresh the item list itself (silently, no spinner): freshly
        // added books and edited metadata (e.g. series) would otherwise only
        // show up after a cold start. refreshProgress used to rebuild from
        // the stale cached items.
        var items = cachedItems
        var fresh: [LibraryItem]?
        if let libraryId {
            do {
                fresh = try await provider.fetchLibraryItems(libraryId: libraryId)
            } catch {
                Logger.library.notice("LIBRARY refresh items failed, cached kept: \(FailureReason.of(error), privacy: .public)")
            }
        }
        if let fresh {
            // Plausibility (like loadContent only persisting a COMPLETE load): a
            // foreground refresh must not shrink the visible library on a partial
            // 2xx answer. And this result is even persisted to the disk cache.
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
    /// when it is not SMALLER than the cache. A partial/hiccuped answer must not
    /// shrink (and then persist) the visible library. Real growth is taken as is.
    /// (A genuine server-side deletion needs an explicit path, not a quiet
    /// foreground shrink. Flagged for a decision, not given a back door here.)
    nonisolated static func plausibleFreshItems(_ fresh: [LibraryItem], cached: [LibraryItem]) -> [LibraryItem] {
        fresh.count >= cached.count ? fresh : cached
    }

    /// Re-mix the list after importing/deleting local files. Without querying
    /// the server again (uses the already-loaded server items).
    /// A title was taken off (or returned to) the Continue rows.
    /// Purely local. Rebuild from what is already loaded, no server round trip
    /// for a decision the user just made on this device.
    func refreshContinueRows() async {
        await rebuild(items: cachedItems, progress: lastProgress)
    }

    /// A position this device just wrote (to the server or into the queue):
    /// the Continue rows learn the moment NOW, not at the next server
    /// refresh. Only the held state changes here; the rebuild follows the
    /// listening revision (play, pause, stop), never a tick.
    func noteLocalProgress(itemId: String, currentTime: Double, duration: Double, isFinished: Bool) {
        guard cachedItems.contains(where: { $0.id == itemId }) else { return }
        let known = lastProgress[itemId]
        let fraction: Double
        if isFinished {
            fraction = 1
        } else if duration > 0 {
            fraction = min(1, max(0, currentTime / duration))
        } else {
            fraction = known?.fraction ?? 0
        }
        lastProgress[itemId] = BookProgress(fraction: fraction, isFinished: isFinished,
                                            lastUpdate: Date().timeIntervalSince1970 * 1000,
                                            currentTime: currentTime)
    }

    /// A server item + (server/local) progress + queued updates → a
    /// display-ready `LibraryEntry`. Extracted so both the full list and the
    /// seed rows (Continue/Recently Added) are prepared exactly the same way.
    nonisolated static func makeEntry(item: LibraryItem,
                                      progress: [String: BookProgress],
                                      queued: [String: SyncQueue.PendingUpdate]) -> LibraryEntry {
        var p = progress[item.id]
        // For MULTI-FILE books the client deliberately sends no server
        // `progress`/`duration` (an explicit 0 would clobber existing server
        // progress). So the server fraction FREEZES while `currentTime` keeps
        // advancing. The authoritative value is `currentTime` over the LOCALLY
        // known total duration. Recompute it whenever both are known and the
        // book is not finished. Previously this only ran for a ~0 server
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
        // Layer not-yet-sent (queued) updates OVER the server state. Otherwise
        // the library shows the old state until the flush, which looks like
        // progress loss. An update the flush drops because the server is
        // further ahead is not shown (`SyncRules.queuedFate`).
        if let q = queued[item.id],
           SyncRules.queuedFate(queuedTime: q.currentTime, queuedIsFinished: q.isFinished,
                                duration: q.duration, server: progress[item.id]) != .drop {
            let duration = q.duration > 0 ? q.duration : (item.media?.duration ?? 0)
            p = BookProgress(
                fraction: duration > 0 ? min(max(q.currentTime / duration, 0), 1) : (p?.fraction ?? 0),
                isFinished: q.isFinished,
                lastUpdate: q.queuedAt ?? p?.lastUpdate ?? 0,
                currentTime: q.currentTime
            )
        }
        // The person's "counts as played" tail, answered against this book's
        // duration. Read only; the server flag and the fraction stay as they are.
        return LibraryEntry(item: item, progress: p?.judged(duration: item.media?.duration,
                                                            tail: PlayedTail.seconds(forItemId: item.id)))
    }

    /// Progress used by the last rebuild, and what a rebuild without a fresh
    /// server answer keeps (otherwise all bars and Continue would blank out).
    private var lastProgress: [String: BookProgress] = [:]

    /// Everything the off-main rebuild computation needs, as a value snapshot.
    /// Started titles outside the server library. Resolved
    /// HERE because the item lookup is main-actor bound, then handed to the
    /// off-main rebuild as plain data.
    @MainActor
    static func continueExtras() -> [LibraryEntry] {
        ContinueSources.started(positions: ListeningStore.positions(),
                                serverKnows: [])
            .compactMap { extra in
                guard let item = AppSession.shared.playableItem(forId: extra.id) else { return nil }
                // `isStarted` reads the FRACTION, so it needs a duration.
                // With one from the mark it is exact, without one the entry
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
        /// Per-item "not under Continue any more" markers.
        var hiddenMarkers: [String: Double] = [:]
        /// Started titles OUTSIDE the server library.
        /// Local sideloads and catalog works, resolved by the caller (their
        /// item lookup is main-actor bound).
        var continueExtras: [LibraryEntry] = []
    }

    nonisolated struct RebuildOutput: Sendable {
        let entries: [LibraryEntry]
        let continueListening: [LibraryEntry]
        /// EVERY started title, including the ones the age cutoff removes from
        /// the row above. Rediscover's "paused" source feeds from this. It
        /// draws exactly the entries Continue drops, so the cutoff MOVES a
        /// title from one row to the other instead of erasing it from both.
        let continueAll: [LibraryEntry]
        let recentlyAdded: [LibraryEntry]
        let sorted: [LibraryEntry]
        let grouped: [GridEntry]
    }

    /// The expensive part of a rebuild. makeEntry over every item, the
    /// Continue/Recently unions and sorts, AND the memoized derived lists. Runs
    /// OFF the main actor over the snapshot; the main actor only assigns.
    nonisolated static func computeRebuild(_ input: RebuildInput) -> RebuildOutput {
        let combined = input.items.map {
            makeEntry(item: $0, progress: input.progress, queued: input.queued)
        }
        // Always mix in local files (preloaded via their provider). Regardless
        // of server status, they are offline available by definition.
        let entries = combined + input.localCache

        // Continue/Recently as the union of the already-loaded pages AND the
        // server seed. So both rows are complete immediately and never get
        // shorter while loading progressively. Already-loaded entries win
        // (fresher progress).
        let byId = Dictionary(combined.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })

        var continueById: [String: LibraryEntry] = [:]
        // Ask the won source, not the raw one. A frozen cached zero
        // must not delete a book from the row it belongs in.
        func started(_ e: LibraryEntry) -> Bool {
            ContinueSources.isStarted(
                serverSaysStarted: e.progress?.isStarted ?? false,
                flushed: ListeningStore.flushed(e.id),
                finished: e.progress?.countsAsFinished ?? false)
        }
        for e in combined where started(e) { continueById[e.id] = e }
        for item in input.seedContinue where byId[item.id] == nil {
            let e = makeEntry(item: item, progress: input.progress, queued: input.queued)
            if started(e) { continueById[e.id] = e }
        }
        // Two things were missing here, and their absence was not a
        // concept. `recentlyAdded` two lines below has had a cap all along.
        // (1) AGE: what has lain untouched for longer is not "continue" any
        //     more, it is a case for Rediscover. Which owns that mechanic
        //     including the threshold. Same constant reused, no second one
        //     invented, so a title cannot sit in both rows at once.
        // (2) CAP: a row is the preview of a page; the complete
        //     stock belongs behind the chevron.
        // The row takes the OTHER classes too. Locally
        // sideloaded books and catalog works keep their position in the same
        // second-backup, and both were structurally invisible here (the row
        // only knew the source it was born from). One collection, so the
        // next class plugs in instead of being forgotten again.
        // Dedupe: the SERVER identity leads. A downloaded ABS book stays one
        // entry, local sideloads are their own identity.
        for extra in input.continueExtras where byId[extra.id] == nil && continueById[extra.id] == nil {
            continueById[extra.id] = extra
        }
        let continueAll = continueById.values
            .sorted { ($0.progress?.lastUpdate ?? 0) > ($1.progress?.lastUpdate ?? 0) }
        // The AGE CUTOFF is GONE.
        // Continue is the row of ALL started books again. A book left lying
        // for four weeks is exactly what is to be continued, not "gone from
        // Continue". Capping (display) and culling (stock) are two different
        // operations. This row caps and never culls.
        // Rediscover keeps feeding from continueAll with its own
        // threshold. The overlap is WANTED (one row answers "what did I
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
        // The line that says what the library was rebuilt FROM: without it
        // an empty library and a wiped one look the same.
        Logger.library.notice("LIBRARY rebuild items=\(items.count) progress=\(progress.count) local=\(self.localCache.count) before=\(self.entries.count)")
        cachedItems = items
        lastProgress = progress
        let input = rebuildInput(items: items, progress: progress)
        // detached because the rebuild is CPU work and the view model is MainActor by default
        let output = await Task.detached(priority: .userInitiated) {
            // Regression guard: the library rebuild must stay off the main actor
            // (it used to hitch scrolling). Fires if it ever drifts back.
            #if DEBUG
            dispatchPrecondition(condition: .notOnQueue(.main))
            #endif
            return Self.computeRebuild(input)
        }.value
        // Layout-shift fix: a progressive page landing mid-scroll used to grow
        // the grid under the finger. Non-initial applies wait for the shared
        // calm gate (BottomBarState). The initial fill (empty library) applies
        // immediately; queued applies flush in order, so the newest state wins.
        if entries.isEmpty {
            apply(output)
        } else {
            ScrollCalm.run { [self] in apply(output) }
        }
        rebuildRunning = false
        if let pending = pendingRebuild {
            pendingRebuild = nil
            await rebuild(items: pending.items, progress: pending.progress)
        }
    }

    /// Everything a rebuild reads beside the server copy, gathered once so
    /// the harness door below builds from exactly the same input.
    private func rebuildInput(items: [LibraryItem], progress: [String: BookProgress]) -> RebuildInput {
        RebuildInput(
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
    }

    private func apply(_ output: RebuildOutput) {
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

    #if DEBUG
    /// The harness's door into the library. The seeded entries become the
    /// SERVER COPY, so every later rebuild (a listening event, a hidden
    /// marker, a source change) keeps them; a seed that only set `entries`
    /// was wiped by the first such rebuild (measured 17.09.2026: rebuild
    /// items=0 before=25). The lists come out of the same rule as a load,
    /// on the main actor because the seed runs before the first frame.
    func _seedForUITest(_ seeded: [LibraryEntry]) {
        var progress: [String: BookProgress] = [:]
        for entry in seeded { if let p = entry.progress { progress[entry.id] = p } }
        cachedItems = seeded.map(\.item)
        lastProgress = progress
        apply(Self.computeRebuild(rebuildInput(items: cachedItems, progress: progress)))
    }
    #endif

    /// Query the local source ONLY via its provider (items + progress). The
    /// core knows neither LocalLibrary nor the `local:` prefix. Called at the
    /// start of every load (in-memory, never an error).
    private func reloadLocalCache() async {
        // Generalized (Booksonic): EVERY secondary audiobook-typed source
        // merges here via its provider. Local files and a Subsonic source the
        // user set to audiobooks. The core still knows no concrete provider
        // and no id namespace; the main (ABS) provider stays the primary path.
        let session = AppSession.shared
        let sources = session.allProviders
            .filter { provider in
                Self.mixesIn(isMain: provider === session.provider,
                             servesBooks: provider.mediaTypes.contains(.audiobooks), available: provider.isAvailable)
            }
            .map { provider in
                SecondaryShelf.Source(key: provider.providerId,
                                      items: { try await provider.fetchLibraryItems(for: .audiobooks) },
                                      progress: { try await provider.fetchAllProgress() })
            }
        // What a source failed to answer, it keeps from the round before.
        let owners = Dictionary(localCache.map { ($0.id, session.provider(for: $0.id).providerId) },
                                uniquingKeysWith: { first, _ in first })
        localCache = await SecondaryShelf.entries(of: sources, previous: localCache, owners: owners)
        secondarySignature = Self.signature(of: session.allProviders)
    }

    /// Which sources feed the audiobook shelf besides the main one, and out
    /// of WHAT, as ONE comparable value. A source that starts or stops
    /// serving books changes it, and so does one that keeps serving them out
    /// of a different library; a plain announcement (a client rebuilt with
    /// the same answer) does not, and that difference is what keeps a start
    /// from listing twice.
    ///
    /// `serving` is carried in the mapped value and NOT in the filter, and
    /// the filter still asks `servesBooks`. Both halves matter: without
    /// `serving` a library that becomes a different one is invisible here
    /// and the shelf keeps ids nobody serves any more; and if `serving` were
    /// allowed to decide WHICH sources count, a source that only serves
    /// music would move this value, and the audiobook shelf would re-fetch
    /// every secondary source over the network for a change that cannot
    /// reach it. `serving` therefore answers for the audiobook type alone.
    /// Which source the audiobook shelf mixes in beside the main one: a
    /// source that serves audiobooks and is available, never the main
    /// source itself.
    nonisolated static func mixesIn(isMain: Bool, servesBooks: Bool, available: Bool) -> Bool {
        !isMain && servesBooks && available
    }

    nonisolated static func secondarySignature(
        of sources: [(id: String, servesBooks: Bool, available: Bool, serving: String)]) -> String {
        sources.filter { $0.servesBooks && $0.available }
            .map { "\($0.id)|\($0.serving)" }.sorted().joined(separator: ",")
    }

    private static func signature(of providers: [any AudioProvider]) -> String {
        secondarySignature(of: providers.map {
            ($0.providerId, $0.mediaTypes.contains(.audiobooks), $0.isAvailable,
             $0.servingSignature(for: .audiobooks))
        })
    }

    /// A source changed WHAT IT SERVES: a toggle, or a server library this app
    /// only just learned about. The second case is the one that needs this
    /// door: a Jellyfin books library is a server answer that arrives a moment
    /// AFTER the start, and the shelf had already been mixed without it, so
    /// the books showed up only at the next launch.
    ///
    /// The secondary sources are asked again and the list is re-mixed from what
    /// is already loaded; the main provider is not queried, because nothing
    /// about it changed. An unchanged set costs no request at all.
    func refreshSecondarySources(from providers: [any AudioProvider]) async {
        let step = Self.secondaryRefreshStep(
            signatureChanged: Self.signature(of: providers) != secondarySignature,
            running: secondaryRefreshRunning)
        switch step {
        case .skip: return
        case .queue: secondaryRefreshPending = true; return
        case .run: break
        }
        secondaryRefreshRunning = true
        defer { secondaryRefreshRunning = false }
        repeat {
            secondaryRefreshPending = false
            await reloadLocalCache()
            await rebuild(items: cachedItems, progress: lastProgress)
        } while secondaryRefreshPending
    }

    /// Whether a runner is inside the two awaits above.
    private var secondaryRefreshRunning = false
    /// An announcement that arrived while one was: the run repeats once at
    /// the end instead of being dropped.
    private var secondaryRefreshPending = false

    /// What a second announcement does while the first is still running.
    ///
    /// The signature gate alone does not hold it: `secondarySignature` is
    /// written at the END of `reloadLocalCache`, so every announcement that
    /// arrives during those two awaits still sees the old value and passes.
    /// One toggle can produce three of them, and then three runs ask every
    /// secondary source over the network at once.
    ///
    /// Dropping them instead would be the opposite mistake: an announcement
    /// during the flight can be the one that matters (a server library that
    /// only just arrived), and the run it came too late for was built on the
    /// state before it. So it is remembered and the run repeats once.
    ///
    /// The neighbour `rebuild` has carried exactly this pair (`rebuildRunning`
    /// plus `pendingRebuild`) since long before; this door was the one without
    /// it.
    nonisolated enum SecondaryRefreshStep: Equatable {
        /// Nothing changed about what the sources serve.
        case skip
        /// Nobody is inside: go.
        case run
        /// Somebody is inside: remember it, the runner repeats.
        case queue
    }

    nonisolated static func secondaryRefreshStep(signatureChanged: Bool,
                                                 running: Bool) -> SecondaryRefreshStep {
        guard signatureChanged else { return .skip }
        return running ? .queue : .run
    }

    #if DEBUG
    /// Harness seam: hands the seeded entries to the rows (measurement of
    /// the fallback path); the same save the load uses.
    func _testPersistCache() {
        var progress: [String: BookProgress] = [:]
        for entry in entries { if let p = entry.progress { progress[entry.id] = p } }
        saveLibraryDiskCache(items: entries.map(\.item), progress: progress)
    }

    /// Test seam: returns once the handed-over cache write has landed.
    func _testAwaitCacheWrite() async {
        await rowChain.awaitPendingWrites()
    }
    #endif

    private func saveLibraryDiskCache(items: [LibraryItem], progress: [String: BookProgress]) {
        // Only write if something actually changed. Otherwise every
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

        // Only the rows a refresh changed go to the database, off the main
        // actor and in order, through the rows' one chain: each write waits
        // for the one before it and takes the newest cache handed over.
        cacheToWrite = LibraryDiskCache(items: items, progress: progress)
        rowChain.write(read: { [weak self] in
            guard let self, let rows = await self.openRows() else { throw RowsNotOpen() }
            let read = try await rows.loadAllCounted()
            return (read.cache, read.skipped)
        }, take: { [weak self] in self?.cacheToWrite }, apply: { [weak self] cache, base, _ in
            guard let self, let rows = await self.openRows() else { return .skipped }
            let started = Date()
            // Against what landed; without a known base against nothing,
            // which upserts and removes nothing. The one store that does not
            // remove what it read under an unknown base, by name: the rows
            // are an image of the servers, a row that stays is replaced or
            // dropped by the next fetch, never a loss.
            let diff = LibraryRowDiff.compute(previous: base.knownValue, current: cache)
            guard !diff.isEmpty else { return .unchanged }
            let removed = diff.itemsRemoved.count + diff.progressRemoved.count
            let counts = try await rows.apply(diff)
            let ms = Int(Date().timeIntervalSince(started) * 1000)
            Logger.library.notice("LIBROWS save: items=\(counts.items) progress=\(counts.progress) removed=\(removed) plan=\(String(describing: base.plan), privacy: .public) ms=\(ms)")
            return .landed
        })
    }

    /// The rows could not be opened; a read after a failed start holds.
    private struct RowsNotOpen: Error {}


    private func openRows() async -> LibraryRowStore? {
        if let rowsOpening { return await rowsOpening.value }
        let database = database
        let opening = Task<LibraryRowStore?, Never> {
            do {
                return try await LibraryRowStore(connection: try database.connection())
            } catch {
                Logger.library.error("LIBROWS open failed reason=\(String(describing: error), privacy: .public)")
                return nil
            }
        }
        rowsOpening = opening
        return await opening.value
    }

    /// The cache from the rows, off-main: on an offline cold start this is
    /// the whole library. A failed read leaves the rows unknown, and then
    /// no write replaces them whole.
    private func loadDiskCache() async -> LibraryDiskCache? {
        // Nothing of the rows goes into memory on a read after a failed
        // start: this run's fetch is the newer image (`rowChain`, whose
        // adoption is set where it is built).
        guard let rows = await openRows() else {
            rowChain.startReadFailedAsAWhole(reason: "rows not open")
            return nil
        }
        do {
            let (cache, skipped) = try await rows.loadAllCounted()
            // Rows that did not decode make the rows unknown, never fresh.
            rowChain.started(rows: cache, skipped: skipped)
            return cache
        } catch {
            rowChain.startReadFailedAsAWhole(reason: String(describing: error))
            return nil
        }
    }

    /// Prefetches only the RELEVANT covers in the background (sequentially, easy
    /// on the often internet-reached server): the top rows (Continue, Recently)
    /// plus the first visible entries of the list. The rest loads lazily on
    /// scroll via `CachedAsyncImage`. This saves hundreds of unnecessary
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
            await Artwork.preload(url)
        }
    }
}
