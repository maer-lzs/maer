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
    case zuletztHinzugefuegt = "Zuletzt hinzugefügt"
    case zuletztGehoert = "Zuletzt gehört"
    var id: String { rawValue }

    /// Sinnvolle Standardrichtung je Sortierart — Titel/Autor alphabetisch
    /// aufsteigend (A→Z), alles Zeitbasierte neuestes zuerst.
    var defaultAscending: Bool {
        switch self {
        case .titel, .autor: return true
        case .zuletztHinzugefuegt, .zuletztGehoert: return false
        }
    }
}

enum FilterOption: String, CaseIterable, Identifiable {
    case alle = "Alle"
    case unfertig = "Unfertig"
    case fertig = "Fertig"
    var id: String { rawValue }
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
        static let sortOption = "librarySortOption"
        static let filterOption = "libraryFilterOption"
        static let sortAscending = "librarySortAscending"
    }

    private let apiClient: APIClient
    private var cachedItems: [LibraryItem] = []
    private var libraryId: String?

    /// Persistenter Zwischenspeicher der Bibliothek — der Grund, warum die
    /// Bücherliste auch komplett offline (z. B. nach App-Neustart ohne Netz)
    /// weiterhin angezeigt wird, statt leer zu sein.
    private struct DiskCache: Codable {
        let items: [LibraryItem]
        let progress: [String: BookProgress]
    }
    private let diskCacheURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("library_cache.json")

    init(apiClient: APIClient) {
        self.apiClient = apiClient

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
        let filtered = entries.filter { entry in
            switch filterOption {
            case .alle: return true
            case .unfertig: return !(entry.progress?.isFinished ?? false)
            case .fertig: return entry.progress?.isFinished ?? false
            }
        }

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
        case .zuletztHinzugefuegt:
            ascendingSorted = filtered.sorted { ($0.item.addedAt ?? 0) < ($1.item.addedAt ?? 0) }
        case .zuletztGehoert:
            ascendingSorted = filtered.sorted { ($0.progress?.lastUpdate ?? 0) < ($1.progress?.lastUpdate ?? 0) }
        }
        return sortAscending ? ascendingSorted : ascendingSorted.reversed()
    }

    /// Alle heruntergeladenen Bücher, alphabetisch — eigene Sektion für den
    /// schnellen Überblick "was kann ich gerade offline hören".
    var downloadedEntries: [LibraryEntry] {
        entries
            .filter { DownloadManager.shared.isDownloaded(itemId: $0.id) }
            .sorted { $0.item.title.localizedCaseInsensitiveCompare($1.item.title) == .orderedAscending }
    }

    func loadLibrary() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            let libraries = try await apiClient.fetchLibraries()
            guard let first = libraries.first else {
                errorMessage = "Keine Bibliothek auf dem Server gefunden."
                return
            }

            async let itemsTask = apiClient.fetchLibraryItems(libraryId: first.id)
            async let progressTask = apiClient.fetchAllProgress()
            let items = try await itemsTask
            let progress = (try? await progressTask) ?? [:]

            libraryId = first.id
            isShowingOfflineCache = false
            rebuild(items: items, progress: progress)
            saveDiskCache(items: items, progress: progress)
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
        guard !cachedItems.isEmpty else { return }
        guard let progress = try? await apiClient.fetchAllProgress() else {
            // Offline oder Fehler: alten Stand behalten, nicht mit leeren
            // Daten überschreiben (sonst verschwinden alle Häkchen/Balken).
            return
        }
        isShowingOfflineCache = false
        rebuild(items: cachedItems, progress: progress)
        saveDiskCache(items: cachedItems, progress: progress)
    }

    private func rebuild(items: [LibraryItem], progress: [String: BookProgress]) {
        cachedItems = items
        let combined = items.map { item in
            LibraryEntry(item: item, progress: progress[item.id])
        }
        entries = combined

        continueListening = combined
            .filter { ($0.progress?.isStarted ?? false) }
            .sorted { ($0.progress?.lastUpdate ?? 0) > ($1.progress?.lastUpdate ?? 0) }

        recentlyAdded = combined
            .sorted { ($0.item.addedAt ?? 0) > ($1.item.addedAt ?? 0) }
            .prefix(15)
            .map { $0 }
    }

    private func saveDiskCache(items: [LibraryItem], progress: [String: BookProgress]) {
        let cache = DiskCache(items: items, progress: progress)
        guard let data = try? JSONEncoder().encode(cache) else { return }
        try? data.write(to: diskCacheURL)
    }

    private func loadDiskCache() -> DiskCache? {
        guard let data = try? Data(contentsOf: diskCacheURL) else { return nil }
        return try? JSONDecoder().decode(DiskCache.self, from: data)
    }

    /// Lädt alle Cover einmal im Hintergrund vor, nacheinander statt
    /// gleichzeitig — schont den (oft übers Internet erreichten) eigenen
    /// Server. Bereits gecachte Cover werden dabei übersprungen (siehe
    /// `ImageCache.preload`), Wiederholungsaufrufe sind also günstig.
    private func prefetchAllCovers() async {
        for item in cachedItems {
            guard let url = apiClient.coverURL(forItemId: item.id) else { continue }
            await ImageCache.shared.preload(url)
        }
    }
}
