import Foundation
import Combine

/// Ein Buch samt (optionalem) Fortschritt — die Einheit, die die Views anzeigen.
struct LibraryEntry: Identifiable {
    let item: LibraryItem
    let progress: BookProgress?
    var id: String { item.id }
}

enum SortOption: String, CaseIterable, Identifiable {
    case titel = "Titel"
    case autor = "Autor"
    case serie = "Serie"
    case zuletztHinzugefuegt = "Zuletzt hinzugefügt"
    case zuletztGehoert = "Zuletzt gehört"
    var id: String { rawValue }

    /// Anzeigename (lokalisiert) — rawValue bleibt stabiler Persistenz-Key.
    var label: String {
        switch self {
        case .titel: return String(localized: "Title")
        case .autor: return String(localized: "Author")
        case .serie: return String(localized: "Series")
        case .zuletztHinzugefuegt: return String(localized: "Recently Added")
        case .zuletztGehoert: return String(localized: "Recently Listened")
        }
    }

    /// Sinnvolle Standardrichtung je Sortierart — Titel/Autor/Serie
    /// alphabetisch aufsteigend (A→Z), alles Zeitbasierte neuestes zuerst.
    var defaultAscending: Bool {
        switch self {
        case .titel, .autor, .serie: return true
        case .zuletztHinzugefuegt, .zuletztGehoert: return false
        }
    }
}

enum FilterOption: String, CaseIterable, Identifiable {
    case alle = "Alle"
    case unfertig = "Unfertig"
    case fertig = "Fertig"
    case heruntergeladen = "Heruntergeladen"
    var id: String { rawValue }

    /// Anzeigename (lokalisiert) — rawValue bleibt stabiler Persistenz-Key.
    var label: String {
        switch self {
        case .alle: return String(localized: "All")
        case .unfertig: return String(localized: "Unfinished")
        case .fertig: return String(localized: "Finished")
        case .heruntergeladen: return String(localized: "Downloaded")
        }
    }
}

/// Persistenter Zwischenspeicher der Bibliothek — der Grund, warum die
/// Bücherliste auch komplett offline (z. B. nach App-Neustart ohne Netz)
/// weiterhin angezeigt wird, statt leer zu sein. Top-level on purpose: nested
/// in the @MainActor class it would inherit its isolation and the detached
/// background encode could not use the Codable conformance.
private nonisolated struct LibraryDiskCache: Codable {
    let items: [LibraryItem]
    let progress: [String: BookProgress]
}

@MainActor
final class LibraryViewModel: ObservableObject {
    @Published var entries: [LibraryEntry] = []
    @Published var continueListening: [LibraryEntry] = []
    @Published var recentlyAdded: [LibraryEntry] = []
    @Published var isLoading = false
    @Published var errorMessage: String?
    /// True, wenn gerade die zwischengespeicherte Offline-Bibliothek gezeigt
    /// wird, weil der Server nicht erreichbar war — für einen dezenten
    /// Hinweis in der UI statt eines harten Fehlers.
    @Published var isShowingOfflineCache = false
    /// True, solange nach der ersten (sofort sichtbaren) Seite noch weitere
    /// Seiten progressiv nachgeladen werden — steuert den „Loading more…"-Fuß.
    @Published var isLoadingMore = false

    /// Sortierung/Filter werden in UserDefaults gemerkt — bleiben also über
    /// App-Neustarts hinweg erhalten. Wechselt der Nutzer die Sortierart,
    /// springt die Richtung auf deren sinnvollen Standard (siehe
    /// `SortOption.defaultAscending`); die Richtung selbst lässt sich danach
    /// per Umschalter im Menü ändern und bleibt dann bis zur nächsten
    /// Sortierart-Änderung bestehen.
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
    /// Vom Server vorgefertigte „Continue"/„Recently Added"-Reihen — in `rebuild`
    /// mit den bereits geladenen Seiten vereinigt, damit die oberen Reihen sofort
    /// vollständig sind und beim Nachladen nie kürzer werden.
    private var librarySeed = LibrarySeed()
    /// Signatur des zuletzt geschriebenen Disk-Caches — vermeidet redundantes
    /// JSON-Schreiben, wenn sich Items/Progress nicht geändert haben.
    private var lastSavedSignature: Int?
    /// Zuletzt über den lokalen Provider geladene Einträge — als Cache, damit
    /// `rebuild` (synchron, viele Aufrufer) sie ohne erneuten async-Fetch
    /// anhängen kann. Aktualisiert in loadLibrary/refresh (immer über den
    /// Provider, nie direkt über LocalLibrary — sonst wird es messy).
    private var localCache: [LibraryEntry] = []

    private let diskCacheURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("library_cache.json")

    init(provider: any AudioProvider) {
        self.provider = provider

        let defaults = UserDefaults.standard

        // Wichtig: `resolvedSortOption` als lokale Variable, nicht über
        // `self.sortOption` zurücklesen — Swift verbietet bei Klassen jeden
        // Zugriff über self, bevor wirklich ALLE gespeicherten Properties
        // (hier: auch das noch folgende sortAscending) einen Wert haben.
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

    /// Die "Alle Bücher"-Liste, nach aktueller Sortierung, Richtung und Filter
    /// aufbereitet.
    var sortedFilteredEntries: [LibraryEntry] {
        let filtered = entries.filter(matchesFilter)

        // Jeder Fall liefert bewusst die AUFSTEIGENDE Reihenfolge — die
        // Richtung wird danach einheitlich über `sortAscending` angewendet,
        // statt in jedem Fall einzeln hin- und herzudenken.
        let ascendingSorted: [LibraryEntry]
        switch sortOption {
        case .titel:
            ascendingSorted = filtered.sorted {
                $0.item.title.localizedCaseInsensitiveCompare($1.item.title) == .orderedAscending
            }
        case .autor:
            ascendingSorted = filtered.sorted {
                ($0.item.author ?? "").localizedCaseInsensitiveCompare($1.item.author ?? "") == .orderedAscending
            }
        case .serie:
            // Serienname enthält bei ABS die Bandnummer („… #2");
            // localizedStandardCompare sortiert #2 vor #10. Bücher ohne Serie
            // ans Ende, dort alphabetisch nach Titel.
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
        return sortAscending ? ascendingSorted : ascendingSorted.reversed()
    }

    private func matchesFilter(_ entry: LibraryEntry) -> Bool {
        switch filterOption {
        case .alle: return true
        case .unfertig: return !(entry.progress?.isFinished ?? false)
        case .fertig: return entry.progress?.isFinished ?? false
        case .heruntergeladen: return DownloadManager.shared.isDownloaded(itemId: entry.id)
        }
    }

    /// Ein Eintrag im „Alle Bücher"-Grid bei Serien-Sortierung: entweder ein
    /// einzelnes Buch oder ein Serien-Stapel.
    enum GridEntry: Identifiable {
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

    /// sortedFilteredEntries, bei dem Serien mit mehr als einem Buch zu einem
    /// Stapel zusammengefasst sind (Reihenfolge innerhalb: Bandnummer, da die
    /// Liste bei Sortierung „Serie" bereits so sortiert ankommt).
    var seriesGroupedEntries: [GridEntry] {
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
        for entry in (sortAscending ? sortedAll : sortedAll.reversed()) {
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
        // Single-book „series" render as a normal book; then apply the
        // filter: singles must match, stacks stay if ANY book matches.
        return result.compactMap { item in
            if case .series(let name, let books) = item {
                if books.count == 1 {
                    return matchesFilter(books[0]) ? .single(books[0]) : nil
                }
                return books.contains(where: matchesFilter) ? .series(name: name, entries: books) : nil
            }
            if case .single(let entry) = item {
                return matchesFilter(entry) ? item : nil
            }
            return item
        }
    }

    /// Bücher nach Autor gruppiert, alphabetisch — fürs Browsing.
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

    /// Bücher nach Genre gruppiert — ein Buch kann in mehreren Genres stehen.
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

    /// Alle heruntergeladenen Bücher, alphabetisch — eigene Sektion für den
    /// schnellen Überblick "was kann ich gerade offline hören".
    var downloadedEntries: [LibraryEntry] {
        entries
            .filter { DownloadManager.shared.isDownloaded(itemId: $0.id) }
            .sorted { $0.item.title.localizedCaseInsensitiveCompare($1.item.title) == .orderedAscending }
    }

    /// Guards against overlapping loads (pull-to-refresh + foreground
    /// refresh + reconnect can fire together → double rebuilds, visible hitch).
    private var loadInFlight = false

    func loadLibrary() async {
        guard !loadInFlight else { return }
        loadInFlight = true
        defer { loadInFlight = false }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        // Lokale Quelle immer zuerst (in-memory, nie ein Fehler) — so sind
        // lokale Titel auch dann da, wenn der Server offline ist.
        await reloadLocalCache()
        do {
            // NUR Buch-Bibliotheken für den Hörbuch-Tab — Podcast-Libraries
            // (mediaType == "podcast") gehören zum Podcast-Provider, nicht hier.
            // Sonst würde `first` ggf. eine Podcast-Library als „Bibliothek"
            // wählen und der Hörbuch-Tab bliebe leer/falsch.
            // Transiente Fehler (Timeout/5xx/Verbindung verloren) kurz mit
            // Backoff wiederholen, bevor ein Fehler den Offline-/Cache-Fallback
            // auslöst — echte Offline-Fehler und 401 werfen weiterhin sofort.
            let libraries = try await withRetry { try await self.provider.fetchLibraries() }
                .filter { !$0.isPodcast }
            // The library chosen in the settings wins; fall back to the first
            // one when nothing is chosen or the chosen one no longer exists.
            let storedId = UserDefaults.standard.string(forKey: AppStorageKeys.selectedLibraryId)
            guard let library = libraries.first(where: { $0.id == storedId }) ?? libraries.first else {
                errorMessage = String(localized: "No library found on the server.")
                return
            }

            async let progressTask = provider.fetchAllProgress()
            // Fertige „Continue"/„Recently Added"-Reihen vom Server (ein kleiner
            // Request) — damit die oberen Reihen SOFORT vollständig stehen,
            // unabhängig davon, auf welcher Seite ein gestartetes Buch liegt.
            async let seedTask = provider.fetchLibrarySeed(libraryId: library.id)

            // Progressives Laden: die erste Seite sofort anzeigen, den Rest
            // seitenweise im Hintergrund anhängen. Alle clientseitigen
            // Funktionen (Sortierung, Filter, Serien-Stapel, Suche) arbeiten
            // auf dem bereits Geladenen und vervollständigen sich, sobald
            // weitere Seiten eintreffen — nichts bricht, es konvergiert nur.
            let pageSize = 50
            let first = try await withRetry {
                try await self.provider.fetchLibraryItemsPage(
                    libraryId: library.id, limit: pageSize, page: 0)
            }
            let progress = (try? await progressTask) ?? [:]
            librarySeed = (try? await seedTask) ?? LibrarySeed()

            libraryId = library.id
            isShowingOfflineCache = false
            var accumulated = first.items
            let total = first.total
            rebuild(items: accumulated, progress: progress)
            isLoading = false   // erstes Bild steht — Spinner weg, Rest lädt leise

            // Restliche Seiten anhängen (im selben Ladevorgang). Ein
            // Netzwerkabbruch mitten im Nachladen behält das bereits Gezeigte,
            // statt in den Offline-Fallback zu springen. Zwischen-Rebuilds
            // gedrosselt (nur jede 3. Seite) — ein garantierter finaler Rebuild
            // danach hält das Ergebnis identisch, spart aber Zwischenarbeit.
            isLoadingMore = accumulated.count < total
            var page = 1
            do {
                while accumulated.count < total {
                    let next = try await provider.fetchLibraryItemsPage(
                        libraryId: library.id, limit: pageSize, page: page)
                    if next.items.isEmpty { break }
                    accumulated += next.items
                    page += 1
                    if page % 3 == 0 { rebuild(items: accumulated, progress: progress) }
                }
            } catch {
                // Abbruch beim Nachladen: geladene Teilliste behalten.
            }
            rebuild(items: accumulated, progress: progress)   // finaler Rebuild
            isLoadingMore = false

            // Nur bei VOLLSTÄNDIG geladener Liste persistieren/aufräumen — sonst
            // würde eine Teilliste den guten Offline-Cache überschreiben bzw.
            // (cleanup) pro-Buch-Keys nicht geladener Bücher fälschlich löschen.
            if accumulated.count >= total {
                saveLibraryDiskCache(items: accumulated, progress: progress)
                let validIds = Set(accumulated.map(\.id))
                Task.detached(priority: .utility) {
                    AppStorageKeys.cleanupPerBookKeys(validItemIds: validIds)
                }
            }
            Task { await prefetchAllCovers() }
        } catch {
            // Nur bei echter Netzwerk-Nichterreichbarkeit als "offline"
            // behandeln — ein anderer Fehler (z. B. Server-Hänger, kaputtes
            // Format) soll nicht fälschlich den Offline-Hinweis zeigen, wenn
            // tatsächlich Verbindung besteht.
            if NetworkStatus.isOfflineError(error), let cache = loadDiskCache() {
                isShowingOfflineCache = true
                // Offline nur, was wirklich abspielbar ist: heruntergeladene Bücher.
                let downloaded = cache.items.filter { DownloadManager.shared.isDownloaded(itemId: $0.id) }
                rebuild(items: downloaded, progress: cache.progress)
            } else if let cache = loadDiskCache() {
                // Anderer Fehler, aber ein Cache existiert: den letzten
                // bekannten Stand stillschweigend weiter zeigen, ohne
                // irreführenden Offline-Hinweis.
                rebuild(items: cache.items, progress: cache.progress)
            } else {
                errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
    }

    /// Aktualisiert leise nur die Fortschrittsdaten (Balken, "Weiter hören"),
    /// ohne die ganze Bücherliste neu zu laden oder einen Spinner zu zeigen.
    /// Wird z. B. aufgerufen, wenn die App wieder in den Vordergrund kommt.
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
        rebuild(items: items, progress: progress)
        saveLibraryDiskCache(items: items, progress: progress)
    }

    /// Nach Import/Löschen lokaler Dateien die Liste neu mischen — ohne den
    /// Server erneut zu befragen (nutzt die bereits geladenen Server-Items).
    func refreshAfterLocalChange() async {
        await reloadLocalCache()
        let progress = (try? await provider.fetchAllProgress()) ?? [:]
        rebuild(items: cachedItems, progress: progress)
    }

    /// Ein Server-Item + (server/lokaler) Fortschritt + gequeuete Updates → ein
    /// anzeigefertiger `LibraryEntry`. Ausgelagert, damit sowohl die Vollliste
    /// als auch die Seed-Reihen (Continue/Kürzlich) exakt gleich aufbereitet
    /// werden.
    private func makeEntry(item: LibraryItem,
                           progress: [String: BookProgress],
                           queued: [String: SyncQueue.PendingUpdate]) -> LibraryEntry {
        var p = progress[item.id]
        // Multi-File-Fallback: Kennt der Server keine fraction (duration
        // dort 0/leer), aber eine Position, aus der LOKAL bekannten
        // Buchdauer nachrechnen — sonst fehlen Balken/„Weiter hören".
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
        // Noch nicht gesendete (gequeuete) Updates ÜBER den Serverstand
        // legen — sonst zeigt die Bibliothek bis zum Flush den alten Stand,
        // was wie Fortschrittsverlust aussieht.
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

    private func rebuild(items: [LibraryItem], progress: [String: BookProgress]) {
        cachedItems = items
        let queued = SyncQueue.shared.allPending()
        let combined = items.map { makeEntry(item: $0, progress: progress, queued: queued) }
        // Lokale Dateien (über ihren Provider vorgeladen, siehe localCache)
        // immer mit einmischen — unabhängig vom Server-Status, sie sind ja
        // per Definition offline verfügbar.
        entries = combined + localCache

        // Continue/Kürzlich als Vereinigung aus den bereits geladenen Seiten UND
        // dem Server-Seed — so sind beide Reihen sofort vollständig und werden
        // beim progressiven Nachladen nie kürzer (ein gestartetes Buch weit
        // hinten in der Liste fehlt sonst, bis seine Seite geladen ist). Bereits
        // geladene Einträge gewinnen (frischerer Fortschritt).
        let byId = Dictionary(combined.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })

        var continueById: [String: LibraryEntry] = [:]
        for e in combined where e.progress?.isStarted ?? false { continueById[e.id] = e }
        for item in librarySeed.continueListening where byId[item.id] == nil {
            let e = makeEntry(item: item, progress: progress, queued: queued)
            if e.progress?.isStarted ?? false { continueById[e.id] = e }
        }
        continueListening = continueById.values
            .sorted { ($0.progress?.lastUpdate ?? 0) > ($1.progress?.lastUpdate ?? 0) }

        var recentById = byId
        for item in librarySeed.recentlyAdded where recentById[item.id] == nil {
            recentById[item.id] = makeEntry(item: item, progress: progress, queued: queued)
        }
        recentlyAdded = recentById.values
            .sorted { ($0.item.addedAt ?? 0) > ($1.item.addedAt ?? 0) }
            .prefix(15)
            .map { $0 }
    }

    /// Lokale Quelle NUR über ihren Provider abfragen (Items + Fortschritt) —
    /// der Core kennt weder LocalLibrary noch den `local:`-Präfix. Wird zu
    /// Beginn jedes Ladevorgangs aufgerufen (in-memory, nie ein Fehler).
    private func reloadLocalCache() async {
        let localProvider = AppSession.shared.localProvider
        let items = (try? await localProvider.fetchLibraryItems(libraryId: "local")) ?? []
        let progress = (try? await localProvider.fetchAllProgress()) ?? [:]
        localCache = items.map { LibraryEntry(item: $0, progress: progress[$0.id]) }
    }

    private func saveLibraryDiskCache(items: [LibraryItem], progress: [String: BookProgress]) {
        // Nur schreiben, wenn sich wirklich etwas geändert hat — sonst schreibt
        // jeder Reload/refreshProgress denselben JSON erneut auf die Platte.
        // Billige Signatur aus ids+addedAt (Items) und keys+lastUpdate (Progress).
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

    private func loadDiskCache() -> LibraryDiskCache? {
        guard let data = try? Data(contentsOf: diskCacheURL) else { return nil }
        return try? JSONDecoder().decode(LibraryDiskCache.self, from: data)
    }

    /// Lädt nur die RELEVANTEN Cover im Hintergrund vor (nacheinander, schont
    /// den oft übers Internet erreichten Server): die oberen Reihen (Continue,
    /// Kürzlich) plus die ersten sichtbaren Einträge der Liste. Der Rest lädt
    /// lazy beim Scrollen über `CachedAsyncImage` — das spart bei großen
    /// Bibliotheken hunderte unnötige Requests. Bereits gecachte Cover werden
    /// übersprungen (siehe `ImageCache.preload`), Wiederholungen sind günstig.
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
