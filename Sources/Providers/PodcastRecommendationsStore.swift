import Foundation
import Combine

/// Empfehlungen für den Podcast-Home-Tab: externe Popularität (PodcastIndex-
/// Trending, gefiltert nach deinen abonnierten Kategorien; iTunes-Top-Charts als
/// Fallback), bereits Abonnierte ausgeschlossen. Ergebnis wird gecacht und nur
/// selten erneuert — keine lokale Statistik.
@MainActor
final class PodcastRecommendationsStore: ObservableObject {
    static let shared = PodcastRecommendationsStore()
    private init() {}

    @Published private(set) var results: [PodcastSearchResult] = []
    private var loadedAt: Date?
    private var isLoading = false

    /// Nur laden, wenn leer oder älter als 6 h. Best effort (Fehler → still).
    func refreshIfNeeded() async {
        guard !isLoading else { return }
        if !results.isEmpty, let at = loadedAt, Date().timeIntervalSince(at) < 6 * 3600 { return }
        isLoading = true
        defer { isLoading = false }

        let cats = subscribedCategories()
        let raw: [PodcastSearchResult]
        do {
            if AppStorageKeys.podcastIndexConfigured {
                raw = try await PodcastIndexDirectory(
                    key: AppStorageKeys.podcastIndexKeyValue,
                    secret: AppStorageKeys.podcastIndexSecretValue
                ).trending(categories: cats)
            } else {
                raw = try await ITunesDirectory().topPodcasts()
            }
        } catch {
            return
        }
        results = excludeSubscribed(raw)
        loadedAt = Date()
    }

    /// Nach dem Abonnieren aus der Liste nehmen.
    func remove(feedURL: String) {
        let n = PodcastSubscriptions.normalizeFeedURL(feedURL)
        results.removeAll { PodcastSubscriptions.normalizeFeedURL($0.feedURL) == n }
    }

    // MARK: - Intern

    /// Häufigste Kategorien der eigenen Abos (RSS + ABS).
    private func subscribedCategories() -> [String] {
        var counts: [String: Int] = [:]
        let shows = PodcastSubscriptions.shared.shows + ABSPodcastProvider.shared.activeShows
        for show in shows {
            for c in show.categories ?? [] { counts[c, default: 0] += 1 }
        }
        return counts.sorted { $0.value > $1.value }.map { $0.key }
    }

    private func excludeSubscribed(_ list: [PodcastSearchResult]) -> [PodcastSearchResult] {
        let subscribed = Set(
            (PodcastSubscriptions.shared.shows + ABSPodcastProvider.shared.shows)
                .map { PodcastSubscriptions.normalizeFeedURL($0.feedURL) }
        )
        var seen = Set<String>()
        return list.filter {
            let n = PodcastSubscriptions.normalizeFeedURL($0.feedURL)
            return !subscribed.contains(n) && seen.insert(n).inserted
        }
    }
}
