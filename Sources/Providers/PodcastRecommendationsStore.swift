import Foundation
import Combine

/// Empfehlungen für den Podcast-Home-Tab, an deine echte Nutzung gekoppelt:
/// gewichtet nach **Hörzeit** (Proxy: gespeicherte Positionen je Show), plus
/// **gleicher Autor/Verlag** (deine meistgehörten Autoren → deren andere Shows)
/// und **thematisch ähnlich** (spezifische Kategorien + Sprache; breite
/// Kategorien runtergewichtet). Bereits Abonnierte ausgeschlossen; gecacht.
@MainActor
final class PodcastRecommendationsStore: ObservableObject {
    static let shared = PodcastRecommendationsStore()
    private init() {}

    @Published private(set) var results: [PodcastSearchResult] = []
    private var loadedAt: Date?
    private var isLoading = false

    /// Sehr breite Kategorien tragen wenig Signal → runtergewichtet.
    private static let broadCategories: Set<String> = [
        "society & culture", "news", "arts", "business", "education", "leisure",
        "government", "religion & spirituality", "kids & family"
    ]

    /// Nur laden, wenn leer oder älter als 6 h. Best effort (Fehler → still).
    func refreshIfNeeded() async {
        guard !isLoading else { return }
        if !results.isEmpty, let at = loadedAt, Date().timeIntervalSince(at) < 6 * 3600 { return }
        isLoading = true
        defer { isLoading = false }

        let listening = listeningByShow()                 // showId → Hörsekunden
        let topAuthors = weightedAuthors(listening)        // meistgehörte Autoren
        let topCats = weightedCategories(listening)        // gewichtete Kategorien
        let lang = dominantLanguage()

        let piConfigured = AppStorageKeys.podcastIndexConfigured
        let directory: PodcastDirectory = piConfigured
            ? PodcastIndexDirectory(key: AppStorageKeys.podcastIndexKeyValue,
                                    secret: AppStorageKeys.podcastIndexSecretValue)
            : ITunesDirectory()

        var pool: [PodcastSearchResult] = []
        var authorHits = Set<String>()   // normalisierte Feed-URLs aus Autor-Expansion

        // 1. Gleicher Autor/Verlag: deren andere Shows über die Suche holen.
        for author in topAuthors.prefix(3) {
            guard let found = try? await directory.search(author) else { continue }
            for r in found where authorMatches(r, author) {
                pool.append(r)
                authorHits.insert(PodcastSubscriptions.normalizeFeedURL(r.feedURL))
            }
        }

        // 2. Thematisch ähnlich: Trending nach spezifischen Kategorien + Sprache
        //    (bzw. iTunes-Top-Charts ohne Key).
        if let pi = directory as? PodcastIndexDirectory {
            if let trend = try? await pi.trending(lang: lang, categories: Array(topCats.prefix(4))) {
                pool += trend
            }
        } else if let it = directory as? ITunesDirectory {
            if let top = try? await it.topPodcasts() { pool += top }
        }

        let filtered = excludeSubscribed(pool)
        results = rank(filtered, authorHits: authorHits, categoryWeights: topCats).prefix(30).map { $0 }
        loadedAt = Date()
    }

    /// Nach dem Abonnieren aus der Liste nehmen.
    func remove(feedURL: String) {
        let n = PodcastSubscriptions.normalizeFeedURL(feedURL)
        results.removeAll { PodcastSubscriptions.normalizeFeedURL($0.feedURL) == n }
    }

    // MARK: - Signale aus der eigenen Nutzung

    private var mineShows: [PodcastShow] {
        PodcastSubscriptions.shared.shows + ABSPodcastProvider.shared.activeShows
    }

    /// Hörzeit je Show (Proxy: Summe der gespeicherten `localPosition`-Sekunden
    /// aller Folgen dieser Show). Retroaktiv, ohne neues Tracking.
    private func listeningByShow() -> [String: Double] {
        var out: [String: Double] = [:]
        for (key, value) in UserDefaults.standard.dictionaryRepresentation() {
            guard key.hasPrefix("localPosition.rss:") || key.hasPrefix("localPosition.abspod:"),
                  let arr = value as? [Double], arr.count == 2 else { continue }
            let epId = String(key.dropFirst("localPosition.".count))
            guard let showId = AppStorageKeys.podcastShowId(forEpisodeId: epId) else { continue }
            out[showId, default: 0] += max(arr[0], 0)
        }
        return out
    }

    /// Autoren nach Hörzeit (meistgehörte zuerst). Shows ohne Hörzeit zählen mit
    /// minimalem Gewicht, damit auch neue Abos etwas beitragen.
    private func weightedAuthors(_ listening: [String: Double]) -> [String] {
        var weight: [String: Double] = [:]
        for show in mineShows {
            guard let author = show.author, !author.isEmpty else { continue }
            weight[author, default: 0] += (listening[show.id] ?? 0) + 1
        }
        return weight.sorted { $0.value > $1.value }.map { $0.key }
    }

    /// Kategorien nach Hörzeit gewichtet; breite Kategorien nur zu 30 %.
    private func weightedCategories(_ listening: [String: Double]) -> [String] {
        var weight: [String: Double] = [:]
        for show in mineShows {
            let base = (listening[show.id] ?? 0) + 1
            for c in show.categories ?? [] {
                let factor = Self.broadCategories.contains(c.lowercased()) ? 0.3 : 1.0
                weight[c, default: 0] += base * factor
            }
        }
        return weight.sorted { $0.value > $1.value }.map { $0.key }
    }

    private func dominantLanguage() -> String? {
        var counts: [String: Int] = [:]
        for show in mineShows {
            if let l = show.language?.prefix(2).lowercased(), !l.isEmpty { counts[String(l), default: 0] += 1 }
        }
        if let top = counts.max(by: { $0.value < $1.value })?.key { return top }
        return Locale.current.language.languageCode?.identifier
    }

    // MARK: - Filtern & Ranking

    private func authorMatches(_ r: PodcastSearchResult, _ author: String) -> Bool {
        let a = author.lowercased()
        if let ra = r.author?.lowercased(), ra.contains(a) || a.contains(ra) { return true }
        return r.title.lowercased().contains(a)
    }

    /// Autor-Treffer zuerst, dann nach gewichteter Kategorie-Nähe.
    private func rank(_ list: [PodcastSearchResult],
                     authorHits: Set<String>,
                     categoryWeights: [String]) -> [PodcastSearchResult] {
        // Kategorie → Rangwert (frühere = höher), für ein weiches Nähe-Maß.
        var catScore: [String: Double] = [:]
        for (i, c) in categoryWeights.enumerated() { catScore[c] = Double(categoryWeights.count - i) }

        func score(_ r: PodcastSearchResult) -> Double {
            (r.categories ?? []).reduce(0) { $0 + (catScore[$1] ?? 0) }
        }
        return list.enumerated()
            .map { (idx, r) in (r: r, author: authorHits.contains(PodcastSubscriptions.normalizeFeedURL(r.feedURL)), score: score(r), idx: idx) }
            .sorted {
                if $0.author != $1.author { return $0.author }        // Autor-Treffer zuerst
                if $0.score != $1.score { return $0.score > $1.score } // dann Kategorie-Nähe
                return $0.idx < $1.idx
            }
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
