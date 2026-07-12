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

        let topCats = weightedCategories()           // deine häufigsten Kategorien
        let lang = dominantLanguage()                // Sprache deiner Bib / des Geräts
        let raw: [PodcastSearchResult]
        do {
            if AppStorageKeys.podcastIndexConfigured {
                raw = try await PodcastIndexDirectory(
                    key: AppStorageKeys.podcastIndexKeyValue,
                    secret: AppStorageKeys.podcastIndexSecretValue
                ).trending(lang: lang, categories: Array(topCats.prefix(4)))
            } else {
                raw = try await ITunesDirectory().topPodcasts()
            }
        } catch {
            return
        }
        results = rank(excludeSubscribed(raw), byOverlapWith: Set(topCats))
        loadedAt = Date()
    }

    /// Nach dem Abonnieren aus der Liste nehmen.
    func remove(feedURL: String) {
        let n = PodcastSubscriptions.normalizeFeedURL(feedURL)
        results.removeAll { PodcastSubscriptions.normalizeFeedURL($0.feedURL) == n }
    }

    // MARK: - Intern

    private var mineShows: [PodcastShow] {
        PodcastSubscriptions.shared.shows + ABSPodcastProvider.shared.activeShows
    }

    /// Kategorien der eigenen Abos nach Häufigkeit (häufigste zuerst).
    private func weightedCategories() -> [String] {
        var counts: [String: Int] = [:]
        for show in mineShows {
            for c in show.categories ?? [] { counts[c, default: 0] += 1 }
        }
        return counts.sorted { $0.value > $1.value }.map { $0.key }
    }

    /// Dominante Sprache deiner Abos (`show.language`), sonst Geräte-Sprache —
    /// als 2-Buchstaben-Code (z. B. „de"). Nil → kein Sprachfilter.
    private func dominantLanguage() -> String? {
        var counts: [String: Int] = [:]
        for show in mineShows {
            if let l = show.language?.prefix(2).lowercased(), !l.isEmpty { counts[String(l), default: 0] += 1 }
        }
        if let top = counts.max(by: { $0.value < $1.value })?.key { return top }
        return Locale.current.language.languageCode?.identifier
    }

    /// Nach thematischer Nähe sortieren: mehr geteilte Top-Kategorien = weiter
    /// vorne; Trending-Reihenfolge als stabiler Tiebreaker.
    private func rank(_ list: [PodcastSearchResult], byOverlapWith mine: Set<String>) -> [PodcastSearchResult] {
        guard !mine.isEmpty else { return list }
        return list.enumerated()
            .map { (idx, r) -> (r: PodcastSearchResult, overlap: Int, idx: Int) in
                let overlap = Set(r.categories ?? []).intersection(mine).count
                return (r, overlap, idx)
            }
            .sorted { $0.overlap != $1.overlap ? $0.overlap > $1.overlap : $0.idx < $1.idx }
            .map { $0.r }
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
