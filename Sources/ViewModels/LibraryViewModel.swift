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
    var id: String { rawValue }
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

    @Published var sortOption: SortOption = .titel
    @Published var filterOption: FilterOption = .alle

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
    }

    /// Die "Alle Bücher"-Liste, nach aktueller Sortierung und Filter aufbereitet.
    var sortedFilteredEntries: [LibraryEntry] {
        let filtered = entries.filter { entry in
            switch filterOption {
            case .alle: return true
            case .unfertig: return !(entry.progress?.isFinished ?? false)
            case .fertig: return entry.progress?.isFinished ?? false
            }
        }
        switch sortOption {
        case .titel:
            return filtered.sorted { $0.item.title.localizedCaseInsensitiveCompare($1.item.title) == .orderedAscending }
        case .autor:
            return filtered.sorted {
                ($0.item.author ?? "").localizedCaseInsensitiveCompare($1.item.author ?? "") == .orderedAscending
            }
        case .zuletztHinzugefuegt:
            return filtered.sorted { ($0.item.addedAt ?? 0) > ($1.item.addedAt ?? 0) }
        }
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
            // Kein Netz o. ä.: mit dem letzten bekannten Stand weitermachen,
            // statt die Bibliothek leer/mit Fehler zu zeigen — sonst wären
            // selbst heruntergeladene Bücher offline nicht mehr auffindbar.
            if let cache = loadDiskCache() {
                isShowingOfflineCache = true
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
