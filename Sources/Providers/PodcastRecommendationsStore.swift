// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation
import Combine
import OSLog

/// Recommendations for the podcast home tab, tied to your real usage: weighted
/// by **listening time** (proxy: stored positions per show), plus **same
/// author/publisher** (your most-listened authors → their other shows) and
/// **thematically similar** (specific categories + language; broad categories
/// downweighted). Already-subscribed excluded; cached.
@MainActor
final class PodcastRecommendationsStore: ObservableObject {
    static let shared = PodcastRecommendationsStore()
    private init() {}

    @Published private(set) var results: [PodcastSearchResult] = [] {
        // #51: a CONTENT identity for snapshot consumers — the count alone
        // missed same-size wholesale replacements (stale sections).
        didSet { contentVersion &+= 1 }
    }
    /// Bumps on every results assignment; `.task(id:)` consumers key on this
    /// instead of `results.count`.
    private(set) var contentVersion: UInt64 = 0
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
    /// 70dd0d8: normalized feed URL → the CATEGORY whose query produced it.
    private var categoryProvenance: [String: String] = [:]
    /// Top categories of the LAST refresh — for the genre reason.
    private var lastTopCategories: [String] = []

    /// The honest recommendation reason for a result (author > genre > popular).
    func reason(for result: PodcastSearchResult) -> Reason {
        let n = PodcastSubscriptions.normalizeFeedURL(result.feedURL)
        if let author = authorProvenance[n] { return .sameAuthor(author) }
        // 70dd0d8 (5): a hit that CAME from a category query says so — the
        // reason must not claim "popular" for something we fetched because
        // the user listens to that category.
        if let category = categoryProvenance[n] { return .genre(category) }
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

    /// 784aceb: a suggestion-language change must bite WITHOUT an app
    /// restart — drop the freshness stamp so the next refresh recomputes;
    /// current results stay visible until the calm-gated replacement lands.
    func invalidateForLanguageChange() {
        loadedAt = nil
    }

    /// Only load if empty or older than 6 h. Best effort (error → silent).
    func refreshIfNeeded() async {
        guard !isLoading else { return }
        if !results.isEmpty, let at = loadedAt, Date().timeIntervalSince(at) < 6 * 3600 { return }
        isLoading = true
        defer { isLoading = false }

        let listening = listeningByShow()                 // showId → seconds listened
        let topAuthors = weightedAuthors(listening)        // most-listened authors
        let topCats = weightedCategories(listening)        // gewichtete Kategorien
        // f79c40c: the EXPLICIT suggestion-language choice beats the guessed
        // dominant feed language (radio-cascade principle); unset keeps the
        // device-locale default via SuggestionLanguages.effective.
        let chosen = SuggestionLanguages.current()
        let lang = UserDefaults.standard.stringArray(forKey: AppStorageKeys.suggestionLanguages) != nil
            ? SuggestionLanguages.podcastIndexLangParameter(chosen)
            : dominantLanguage()

        // feb46bb: the ONE selection — Apple off is a hard no-request gate.
        // Without any directory the pool stays empty, honestly: recommending
        // needs a catalog to recommend FROM.
        let directory: PodcastDirectory
        switch PodcastDirectorySelection.current {
        case .podcastIndex:
            directory = PodcastIndexDirectory(key: AppStorageKeys.podcastIndexEffectiveKey,
                                              secret: AppStorageKeys.podcastIndexEffectiveSecret)
        case .itunes:
            directory = ITunesDirectory()
        case .none:
            results = []
            loadedAt = Date()
            Logger.rss.notice("RECO skipped — Apple catalog off, no PodcastIndex key")
            return
        }

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

        // 2. Thematically similar. 70dd0d8/d05124b: the categories have to
        //    reach the QUERY — the same class as the LibriVox bug, where the
        //    wrong query (new arrivals instead of the download ranking) made
        //    the ranking irrelevant.
        categoryProvenance = [:]
        var categoryHits = 0
        if let pi = directory as? PodcastIndexDirectory {
            // PI keeps compound Apple names apart ("Society" / "Culture"),
            // so map FIRST and cap afterwards — otherwise dead compound
            // terms use up the few slots.
            let terms = Array(PodcastCategoryMapping.podcastIndexCategories(for: topCats).prefix(3))
            // One query per term instead of one combined `cat` list: the
            // AND/OR semantics of multiple values is not documented and I
            // have no key to measure it. Separate queries are correct under
            // BOTH readings — an intersection cannot silently starve the row.
            for term in terms {
                guard let trend = try? await pi.trending(lang: lang, categories: [term]) else {
                    Logger.rss.notice("RECO pi-trending cat=\(term, privacy: .public) FAILED")
                    continue
                }
                Logger.rss.notice("RECO pi-trending cat=\(term, privacy: .public) hits=\(trend.count)")
                categoryHits += trend.count
                for result in trend {
                    pool.append(result)
                    let n = PodcastSubscriptions.normalizeFeedURL(result.feedURL)
                    if categoryProvenance[n] == nil { categoryProvenance[n] = term }
                }
            }
            Logger.rss.notice("RECO branch=pi langs=\(chosen.joined(separator: ","), privacy: .public) raw=\(topCats.prefix(4).joined(separator: "|"), privacy: .public) mapped=\(terms.joined(separator: "|"), privacy: .public) hits=\(categoryHits)")
            if categoryHits < Self.minCategoryHits {
                // Honest fill-up, and the log says WHY it happened.
                if let trend = try? await pi.trending(lang: lang, categories: []) {
                    pool += trend
                    Logger.rss.notice("RECO fill=generic reason=\(terms.isEmpty ? "no-mapped-categories" : "category-trending-thin", privacy: .public)")
                }
            }
        } else if let it = directory as? ITunesDirectory {
            // 70dd0d8: without a key the row used to fetch the GENRELESS top
            // chart — mainstream by construction, no matter how well ranked.
            let genreIds = Array(PodcastCategoryMapping.itunesGenreIds(for: topCats).prefix(3))
            for genreId in genreIds {
                guard let top = try? await it.topPodcasts(genreId: genreId) else {
                    Logger.rss.notice("RECO itunes-genre id=\(genreId) FAILED")
                    continue
                }
                Logger.rss.notice("RECO itunes-genre id=\(genreId) hits=\(top.count)")
                categoryHits += top.count
                let category = PodcastCategoryMapping.appleCategory(forGenreId: genreId)
                for result in top {
                    pool.append(result)
                    let n = PodcastSubscriptions.normalizeFeedURL(result.feedURL)
                    if categoryProvenance[n] == nil, let category { categoryProvenance[n] = category }
                }
            }
            Logger.rss.notice("RECO branch=itunes langs=\(chosen.joined(separator: ","), privacy: .public) raw=\(topCats.prefix(4).joined(separator: "|"), privacy: .public) genres=\(genreIds.map(String.init).joined(separator: "|"), privacy: .public) hits=\(categoryHits)")
            if categoryHits < Self.minCategoryHits {
                // No listening history (fresh install) ⇒ the generic chart is
                // the HONEST answer, not a fallback for a broken query.
                if let top = try? await it.topPodcasts() {
                    pool += top
                    Logger.rss.notice("RECO fill=generic reason=\(genreIds.isEmpty ? "no-mapped-categories" : "genre-charts-thin", privacy: .public)")
                }
            }
        }

        let filtered = excludeSubscribed(pool)
        let ranked = rank(filtered, authorHits: authorHits, categoryWeights: topCats).prefix(30).map { $0 }
        // 51612b4: the CHART share rotates daily — the personally justified
        // entries (author/genre) keep their signal order and their slots.
        // One pool feeds Home, tab and full page, so all three turn together.
        results = Self.rotatingCharts(
            ranked,
            isChart: { self.reason(for: $0) == .popular },
            daySeed: CatalogRotation.dayIndex(on: Date()))
        loadedAt = Date()
    }

    /// Slots-preserving daily rotation: the chart entries move through their
    /// OWN slots, everything with a personal reason stays exactly where the
    /// ranking put it. Pure and tested.
    nonisolated static func rotatingCharts(
        _ list: [PodcastSearchResult],
        isChart: (PodcastSearchResult) -> Bool,
        daySeed: Int
    ) -> [PodcastSearchResult] {
        let chartIndexes = list.indices.filter { isChart(list[$0]) }
        guard chartIndexes.count > 1 else { return list }
        let charts = chartIndexes.map { list[$0] }
        let shift = daySeed % charts.count
        let rotated = Array(charts[shift...] + charts[..<shift])
        var out = list
        for (slot, entry) in zip(chartIndexes, rotated) { out[slot] = entry }
        return out
    }

    /// Below this many category hits the generic chart fills up — the row
    /// must not stay half empty just because a category is thin.
    private static let minCategoryHits = 10

    /// Remove from the list after subscribing.
    func remove(feedURL: String) {
        let n = PodcastSubscriptions.normalizeFeedURL(feedURL)
        results.removeAll { PodcastSubscriptions.normalizeFeedURL($0.feedURL) == n }
    }

    // MARK: - "Not interested" (5add86b, correction 6ee3f4e)

    /// Permanently hidden recommendations — a dictionary so the RELEASE page
    /// can show a name, not a feed URL. Filtering happens in THIS store, whose
    /// results only ever feed the three recommendation surfaces: search,
    /// genre charts and links never ask here, so what the user actively
    /// steers to stays visible — the correction holds structurally.
    private static let hiddenKey = "podcastRecommendationsHidden"
    private(set) var hiddenByFeed: [String: String] = {
        (UserDefaults.standard.dictionary(forKey: hiddenKey) as? [String: String]) ?? [:]
    }()

    /// "Not interested": out of all three surfaces at once, permanently.
    func hide(_ result: PodcastSearchResult) {
        let n = PodcastSubscriptions.normalizeFeedURL(result.feedURL)
        hiddenByFeed[n] = result.title
        UserDefaults.standard.set(hiddenByFeed, forKey: Self.hiddenKey)
        results.removeAll { PodcastSubscriptions.normalizeFeedURL($0.feedURL) == n }
    }

    /// The release path (settings): the show may be recommended again.
    func unhide(normalizedFeed: String) {
        hiddenByFeed.removeValue(forKey: normalizedFeed)
        UserDefaults.standard.set(hiddenByFeed, forKey: Self.hiddenKey)
        loadedAt = nil   // the next refresh may bring it back
        objectWillChange.send()
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
                  let arr = value as? [Double], arr.count >= 2 else { continue }
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
        let shows = PodcastSubscriptions.shared.shows + ABSPodcastProvider.shared.shows
        let visible = Self.excludingSubscribed(
            list,
            subscribedNormalizedFeeds: Set(shows.map { PodcastSubscriptions.normalizeFeedURL($0.feedURL) }),
            subscribedTitles: shows.map(\.title))
        // Same mechanics as the subscribed filter, one more set.
        return visible.filter {
            hiddenByFeed[PodcastSubscriptions.normalizeFeedURL($0.feedURL)] == nil
        }
    }

    /// Pure (tested): drop already-subscribed feeds + duplicates, order kept.
    /// A subscribed show must never appear as a recommendation — the Home
    /// Discover row filters through this too (subscriptions can happen after
    /// the pool was built).
    ///
    /// fb94905: the URL is not enough. The premium and the free variant of the
    /// SAME show live on different URLs (podcatcher vs. Simplecast), so the
    /// free twin of a premium subscription slipped through — same for a
    /// hoster move or a network feed beside the own one. The show IDENTITY
    /// decides too, via the existing conservative `sameShow` (exact title
    /// after folding; no substring matching, so two genuinely different shows
    /// with similar titles both stay).
    nonisolated static func excludingSubscribed(
        _ list: [PodcastSearchResult], subscribedNormalizedFeeds: Set<String>,
        subscribedTitles: [String] = []
    ) -> [PodcastSearchResult] {
        var seen = Set<String>()
        return list.filter { candidate in
            let n = PodcastSubscriptions.normalizeFeedURL(candidate.feedURL)
            guard !subscribedNormalizedFeeds.contains(n), seen.insert(n).inserted else { return false }
            return !subscribedTitles.contains { PodcastPremiumMatch.sameShow(titleA: $0, titleB: candidate.title) }
        }
    }
}
