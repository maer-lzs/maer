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

    @Published var sortOption: SortOption = .titel
    @Published var filterOption: FilterOption = .alle

    private let apiClient: APIClient
    private var cachedItems: [LibraryItem] = []
    private var libraryId: String?

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
            rebuild(items: items, progress: progress)
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    /// Aktualisiert leise nur die Fortschrittsdaten (Balken, "Weiter hören"),
    /// ohne die ganze Bücherliste neu zu laden oder einen Spinner zu zeigen.
    /// Wird z. B. aufgerufen, wenn die App wieder in den Vordergrund kommt.
    func refreshProgress() async {
        guard !cachedItems.isEmpty else { return }
        let progress = (try? await apiClient.fetchAllProgress()) ?? [:]
        rebuild(items: cachedItems, progress: progress)
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
}
