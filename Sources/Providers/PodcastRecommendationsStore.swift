import Foundation
import Combine

/// Recommendations for the podcast home tab, tied to your real usage: weighted
/// by **listening time** (proxy: stored positions per show), plus **same
/// author/publisher** (your most-listened authors → their other shows) and
/// **thematically similar** (specific categories + language; broad categories
/// downweighted). Already-subscribed excluded; cached.
@MainActor
final class PodcastRecommendationsStore: ObservableObject {
    static let shared = PodcastRecommendationsStore()
    private init() {}

    @Published private(set) var results: [PodcastSearchResult] = []
    private var loadedAt: Date?
    private var isLoading = false

    /// Home "Discover" (Teil 4): where a recommendation came from — the honest
    /// subtitle reason. Derived ONLY from local signals against the public
    /// catalog; no profile leaves the device.
    enum Reason: Equatable {
        /// From an author/publisher you already listen to.
        case sameAuthor(String)
        /// Its categories match your locally weighted top categories.
        case genre(String)
        /// From the catalog's trending/top charts.
        case popular
    }
    /// Provenance per normalized feed URL, recorded while building the pool.
    private var authorProvenance: [String: String] = [:]
    /// Top categories of the LAST refresh — for the genre reason.
    private var lastTopCategories: [String] = []

    /// The honest recommendation reason for a result (author > genre > popular).
    func reason(for result: PodcastSearchResult) -> Reason {
        let n = PodcastSubscriptions.normalizeFeedURL(result.feedURL)
        if let author = authorProvenance[n] { return .sameAuthor(author) }
        if let cat = (result.categories ?? []).first(where: { lastTopCategories.contains($0) }) {
            return .genre(cat)
        }
        return .popular
    }

    /// Sehr breite Kategorien tragen wenig Signal → runtergewichtet.
    private static let broadCategories: Set<String> = [
        "society & culture", "news", "arts", "business", "education", "leisure",
        "government", "religion & spirituality", "kids & family"
    ]

    /// Only load if empty or older than 6 h. Best effort (error → silent).
    func refreshIfNeeded() async {
        guard !isLoading else { return }
        if !results.isEmpty, let at = loadedAt, Date().timeIntervalSince(at) < 6 * 3600 { return }
        isLoading = true
        defer { isLoading = false }

        let listening = listeningByShow()                 // showId → seconds listened
        let topAuthors = weightedAuthors(listening)        // most-listened authors
        let topCats = weightedCategories(listening)        // gewichtete Kategorien
        let lang = dominantLanguage()

        let piConfigured = AppStorageKeys.podcastIndexConfigured
        let directory: PodcastDirectory = piConfigured
            ? PodcastIndexDirectory(key: AppStorageKeys.podcastIndexKeyValue,
                                    secret: AppStorageKeys.podcastIndexSecretValue)
            : ITunesDirectory()

        var pool: [PodcastSearchResult] = []
        var authorHits = Set<String>()   // normalized feed URLs from author expansion

        // 1. Same author/publisher: fetch their other shows via search.
        authorProvenance = [:]
        for author in topAuthors.prefix(3) {
            guard let found = try? await directory.search(author) else { continue }
            for r in found where authorMatches(r, author) {
                pool.append(r)
                let n = PodcastSubscriptions.normalizeFeedURL(r.feedURL)
                authorHits.insert(n)
                authorProvenance[n] = author
            }
        }
        lastTopCategories = Array(topCats.prefix(6))

        // 2. Thematically similar: trending by specific categories + language
        //    (or iTunes top charts without a key).
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

    /// Remove from the list after subscribing.
    func remove(feedURL: String) {
        let n = PodcastSubscriptions.normalizeFeedURL(feedURL)
        results.removeAll { PodcastSubscriptions.normalizeFeedURL($0.feedURL) == n }
    }

    // MARK: - Signals from your own usage

    private var mineShows: [PodcastShow] {
        PodcastSubscriptions.shared.shows + ABSPodcastProvider.shared.activeShows
    }

    /// Listening time per show (proxy: sum of the stored `localPosition` seconds
    /// of all this show's episodes). Retroactive, without new tracking.
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

    /// Authors by listening time (most-listened first). Shows without listening
    /// time count with minimal weight so new subscriptions contribute too.
    private func weightedAuthors(_ listening: [String: Double]) -> [String] {
        var weight: [String: Double] = [:]
        for show in mineShows {
            guard let author = show.author, !author.isEmpty else { continue }
            weight[author, default: 0] += (listening[show.id] ?? 0) + 1
        }
        return weight.sorted { $0.value > $1.value }.map { $0.key }
    }

    /// Categories weighted by listening time; broad categories only at 30 %.
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

    /// Author hits + category proximity as the base rank, then mix by
    /// round-robin across the authors (max 3 per author) — so no publisher
    /// (e.g. "Die Zeit") dominates the top spots.
    private func rank(_ list: [PodcastSearchResult],
                     authorHits: Set<String>,
                     categoryWeights: [String]) -> [PodcastSearchResult] {
        var catScore: [String: Double] = [:]
        for (i, c) in categoryWeights.enumerated() { catScore[c] = Double(categoryWeights.count - i) }
        func score(_ r: PodcastSearchResult) -> Double {
            (r.categories ?? []).reduce(0) { $0 + (catScore[$1] ?? 0) }
        }

        // 1. Base order (author hits first, then category proximity).
        let ordered = list.enumerated()
            .map { (idx, r) in (r: r, author: authorHits.contains(PodcastSubscriptions.normalizeFeedURL(r.feedURL)), score: score(r), idx: idx) }
            .sorted {
                if $0.author != $1.author { return $0.author }
                if $0.score != $1.score { return $0.score > $1.score }
                return $0.idx < $1.idx
            }
            .map { $0.r }

        // 2. Group by author (order = priority), cap per author.
        var groups: [String: [PodcastSearchResult]] = [:]
        var authorOrder: [String] = []
        for r in ordered {
            let key = r.author.flatMap { $0.isEmpty ? nil : $0.lowercased() } ?? r.title.lowercased()
            if groups[key] == nil { authorOrder.append(key); groups[key] = [] }
            if groups[key]!.count < 3 { groups[key]!.append(r) }
        }

        // 3. Round-robin: one hit per author each round → interleaved.
        var result: [PodcastSearchResult] = []
        var round = 0, progressed = true
        while progressed {
            progressed = false
            for key in authorOrder where round < groups[key]!.count {
                result.append(groups[key]![round]); progressed = true
            }
            round += 1
        }
        return result
    }

    private func excludeSubscribed(_ list: [PodcastSearchResult]) -> [PodcastSearchResult] {
        let subscribed = Set(
            (PodcastSubscriptions.shared.shows + ABSPodcastProvider.shared.shows)
                .map { PodcastSubscriptions.normalizeFeedURL($0.feedURL) }
        )
        return Self.excludingSubscribed(list, subscribedNormalizedFeeds: subscribed)
    }

    /// Pure (tested): drop already-subscribed feeds + duplicates, order kept.
    /// A subscribed show must never appear as a recommendation — the Home
    /// Discover row filters through this too (subscriptions can happen after
    /// the pool was built).
    nonisolated static func excludingSubscribed(
        _ list: [PodcastSearchResult], subscribedNormalizedFeeds: Set<String>
    ) -> [PodcastSearchResult] {
        var seen = Set<String>()
        return list.filter {
            let n = PodcastSubscriptions.normalizeFeedURL($0.feedURL)
            return !subscribedNormalizedFeeds.contains(n) && seen.insert(n).inserted
        }
    }
}
