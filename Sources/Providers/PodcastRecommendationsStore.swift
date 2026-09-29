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
        // A CONTENT identity for snapshot consumers. The count alone
        // missed same-size wholesale replacements (stale sections).
        didSet { contentVersion &+= 1 }
    }
    /// Bumps on every results assignment; `.task(id:)` consumers key on this
    /// instead of `results.count`.
    private(set) var contentVersion: UInt64 = 0
    private var loadedAt: Date?
    private var isLoading = false

    /// Home "Discover" (Teil 4): where a recommendation came from. The honest
    /// subtitle reason. Derived ONLY from local signals against the public
    /// catalog; no profile leaves the device.
    enum Reason: Equatable {
        /// From an author/publisher you already listen to. `likeShow` names
        /// the show of YOURS that carries that publisher, when it is known:
        /// „from the same publisher as X" says WHY this arrived, while the
        /// publisher's name alone only says who made it. Nil when the top
        /// author came from a co-listened show or from a fold that no owned
        /// title matches exactly; then the older wording stands, which is
        /// true but says less.
        case sameAuthor(String, likeShow: String?)
        /// Its categories match your locally weighted top categories.
        case genre(String)
        /// From the catalog's trending/top charts.
        case popular
    }
    /// EVERY card explains its real source. The line
    /// never lies (per-source provenance) and never stays silent. The ONE
    /// wording for all surfaces (Home row, tab row, full page). A surface
    /// that passes no subtitle reads as "the line is gone" while another
    /// still carries it.
    nonisolated static func reasonLine(_ reason: Reason) -> String {
        switch reason {
        case .sameAuthor(_, .some(let show)):
            return String(localized: "From the same publisher as \(show)")
        case .sameAuthor(let author, nil):
            return String(localized: "Because you listen to \(author)")
        // "a lot of" is the audible difference to the author line: a
        // category weight must never SOUND like an author hit, and with
        // one shared wording it did ("Because you listen to History"
        // reads like a show named History).
        case .genre(let genre): return String(localized: "Because you listen to a lot of \(genre)")
        case .popular: return String(localized: "Popular with other listeners")
        }
    }

    /// Provenance per normalized feed URL, recorded while building the pool.
    private var authorProvenance: [String: String] = [:]
    /// Normalized feed URL → the title of MY show that carries the same
    /// publisher. The reason line names it, so the person sees which of their
    /// own shows produced the suggestion.
    private var authorSeedShow: [String: String] = [:]
    /// Normalized feed URL → the CATEGORY whose query produced it.
    private var categoryProvenance: [String: String] = [:]
    /// Top categories of the LAST refresh. For the genre reason.
    private var lastTopCategories: [String] = []

    /// The honest recommendation reason for a result (author > genre > popular).
    func reason(for result: PodcastSearchResult) -> Reason {
        let n = PodcastSubscriptions.normalizeFeedURL(result.feedURL)
        if let author = authorProvenance[n] { return .sameAuthor(author, likeShow: authorSeedShow[n]) }
        // A hit that CAME from a category query says so. The
        // reason must not claim "popular" for something we fetched because
        // the user listens to that category.
        if let category = categoryProvenance[n] { return .genre(category) }
        if let cat = (result.categories ?? []).first(where: { lastTopCategories.contains($0) }) {
            return .genre(cat)
        }
        return .popular
    }

    /// Sehr breite Kategorien tragen wenig Signal → runtergewichtet.
    nonisolated static let broadCategories: Set<String> = [
        "society & culture", "news", "arts", "business", "education", "leisure",
        "government", "religion & spirituality", "kids & family"
    ]

    /// A suggestion-language change must bite WITHOUT an app
    /// restart. Drop the freshness stamp so the next refresh recomputes;
    /// current results stay visible until the calm-gated replacement lands.
    func invalidateForLanguageChange() {
        loadedAt = nil
    }

    /// Only load if empty or older than 6 h. Best effort (error → silent).
    func refreshIfNeeded() async {
        guard !isLoading else { return }
        if !results.isEmpty, let at = loadedAt, Date().timeIntervalSince(at) < 6 * 3600 { return }
        #if DEBUG
        // In the UI-test harness this row loaded LIVE from the
        // directory. The seed gated the library but nobody gated the
        // recommendations. That made a journey's precondition a bet on
        // network latency: a fast answer filled the row, pushed the seed book
        // out of the lazy viewport and turned the verdict red; a slow one
        // left it green. A transport event must never decide a verdict.
        // Seeded instead of empty, so the row GEOMETRY stays realistic.
        if UITestSeed.isActive {
            results = UITestSeed.recommendations
            loadedAt = Date()
            return
        }
        #endif
        isLoading = true
        defer { isLoading = false }

        // showId → seconds listened, with each folded feed's survivor
        // carrying its twins' time; otherwise folding would COST a show its
        // history whenever that history sits under the other copy's id.
        let listening = PodcastShowMerge.liftingTwins(listeningByShow(), groups: mineGroups)
        let taste = tasteShows                             // subscriptions + co-listened at half
        let topAuthors = Self.weightedAuthors(taste, listening: listening)
        let topCats = Self.weightedCategories(taste, listening: listening)
        // The EXPLICIT suggestion-language choice beats the guessed
        // dominant feed language (radio-cascade principle); unset keeps the
        // device-locale default via SuggestionLanguages.effective.
        let chosen = SuggestionLanguages.current()
        let lang = AppStorageKeys.stringArray(AppStorageKeys.suggestionLanguages) != nil
            ? SuggestionLanguages.podcastIndexLangParameter(chosen)
            : dominantLanguage()

        // The ONE selection. Apple off is a hard no-request gate.
        // Without any directory the pool stays empty, honestly: recommending
        // needs a catalog to recommend FROM.
        guard let directory = PodcastDirectorySelection.directory() else {
            results = []
            loadedAt = Date()
            Logger.rss.notice("RECO skipped — Apple catalog off, no PodcastIndex key")
            return
        }

        var pool: [PodcastSearchResult] = []
        var authorHits = Set<String>()   // normalized feed URLs from author expansion

        // 1. Same author/publisher: fetch their other shows via search.
        authorProvenance = [:]
        authorSeedShow = [:]
        // Which of MY shows carries which publisher. Built from the seed, so
        // the reason line can name the show instead of the bare publisher.
        var ownTitleByAuthor: [String: String] = [:]
        for show in mineShows {
            guard let author = show.author, !author.isEmpty, ownTitleByAuthor[author] == nil else { continue }
            ownTitleByAuthor[author] = show.title
        }
        for author in topAuthors.prefix(3) {
            guard let found = try? await directory.search(author) else { continue }
            for r in found where authorMatches(r, author) {
                pool.append(r)
                let n = PodcastSubscriptions.normalizeFeedURL(r.feedURL)
                authorHits.insert(n)
                authorProvenance[n] = author
                authorSeedShow[n] = ownTitleByAuthor[author]
            }
        }
        lastTopCategories = Array(topCats.prefix(6))

        // 2. Thematically similar: the categories have to reach the QUERY.
        //    the same class as the LibriVox bug, where the
        //    wrong query (new arrivals instead of the download ranking) made
        //    the ranking irrelevant.
        categoryProvenance = [:]
        var categoryHits = 0
        if let pi = directory as? PodcastIndexDirectory {
            // PI keeps compound Apple names apart ("Society" / "Culture"),
            // so map FIRST and cap afterwards. Otherwise dead compound
            // terms use up the few slots.
            let terms = Array(PodcastCategoryMapping.podcastIndexCategories(for: topCats).prefix(3))
            // One query per term instead of one combined `cat` list: the
            // AND/OR semantics of multiple values is not documented and I
            // have no key to measure it. Separate queries are correct under
            // BOTH readings. An intersection cannot silently starve the row.
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
            // Without a key the row used to fetch the GENRELESS top
            // chart. Mainstream by construction, no matter how well ranked.
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
        // The CHART share rotates daily. The personally justified
        // entries (author/genre) keep their signal order and their slots.
        // One pool feeds Home, tab and full page, so all three turn together.
        // The SHOWN picks prefer candidates whose artwork can
        // actually load. The same idea as the catalog picks, with podcast
        // means. Three-way ladder: a missing/404 artwork DEFERS the entry
        // (the next candidate moves up), a transport failure is `unknown`
        // and stays usable. A service outage must never empty the row.
        // The DIRECTORY already answered "is this deliverable" for every feed
        // it indexes. Reading that costs no request and runs before the
        // artwork probe, so the probe does not spend its budget on feeds the
        // index gave up on. An order, never a filter: a directory having a bad
        // day must not be able to empty the row.
        let byHealth = PodcastFeedLiveness.demotingDoubtful(ranked) { $0.liveness }
        let probed = await Self.preferLoadableArtwork(byHealth, shown: Self.shownRowLength)
        // The before/after witness. Shares of the SHOWN cut under
        // the old order, logged next to the new one below.
        let beforeShares = Self.reasonShares(Array(probed.prefix(Self.shownRowLength)),
                                             reason: { self.reason(for: $0) })
        // The list is ordered whole (all three surfaces read it), but the
        // author SHARE is a share of the row a person sees.
        let prioritised = Self.composePriority(probed, reason: { self.reason(for: $0) },
                                               limit: probed.count,
                                               rowLength: Self.shownRowLength)
        results = Self.rotatingCharts(
            prioritised,
            isChart: { self.reason(for: $0) == .popular },
            daySeed: CatalogRotation.dayIndex(on: Date()))
        loadedAt = Date()
        // The share witness. Does the equality match still deliver
        // on THIS profile? One line per refresh answers it from the device.
        let after = Self.reasonShares(results, reason: { self.reason(for: $0) })
        let afterShown = Self.reasonShares(Array(results.prefix(Self.shownRowLength)),
                                           reason: { self.reason(for: $0) })
        Logger.rss.notice("RECO reasons: author=\(after.author) genre=\(after.genre) charts=\(after.charts) of \(self.results.count)")
        Logger.rss.notice("RECO priority shown6: before a=\(beforeShares.author) g=\(beforeShares.genre) c=\(beforeShares.charts) → after a=\(afterShown.author) g=\(afterShown.genre) c=\(afterShown.charts)")
    }

    /// Move entries whose artwork demonstrably does not load behind the
    /// others. Only for the FEW that are shown, and only reordering: nothing
    /// is dropped, so a wholesale outage costs order, not content.
    static func preferLoadableArtwork(_ entries: [PodcastSearchResult],
                                      shown: Int) async -> [PodcastSearchResult] {
        var good: [PodcastSearchResult] = []
        var deferred: [PodcastSearchResult] = []
        for entry in entries.prefix(shown * 2) {
            if await artworkLoads(entry) { good.append(entry) } else { deferred.append(entry) }
            if good.count >= shown { break }
        }
        let probedIDs = Set((good + deferred).map(\.id))
        return good + deferred + entries.filter { !probedIDs.contains($0.id) }
    }

    private static func artworkLoads(_ entry: PodcastSearchResult) async -> Bool {
        guard let raw = entry.artworkURL, let url = URL(string: raw) else { return false }
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        request.timeoutInterval = 6
        // bearable, because unknown stays usable: only a clear no takes the tile.
        guard let (_, http) = try? await HTTP.data(for: request, lane: .stream),
              let http else { return true }   // unknown stays usable
        return (200...299).contains(http.statusCode)
    }

    /// Slots-preserving daily rotation: the chart entries move through their
    /// OWN slots, everything with a personal reason stays exactly where the
    /// ranking put it. Pure and tested.
    /// Share triple for the RECO log lines (pure).
    nonisolated static func reasonShares(_ list: [PodcastSearchResult],
                                         reason: (PodcastSearchResult) -> Reason)
        -> (author: Int, genre: Int, charts: Int) {
        var a = 0, g = 0, c = 0
        for r in list {
            switch reason(r) {
            case .sameAuthor: a += 1
            case .genre: g += 1
            case .popular: c += 1
            }
        }
        return (a, g, c)
    }

    /// Author/publisher parallels come FIRST. Up to about
    /// half the row, at most `perAuthorCap` shows per author. Then category,
    /// charts last as the guaranteed filler (the row never shrinks on thin
    /// author days). The cap is ROW-wide (it also counts an author's category
    /// cards), or "more ZEIT" turns into "only ZEIT". Pure and order-stable
    /// within each source group.
    nonisolated static func composePriority(
        _ list: [PodcastSearchResult],
        reason: (PodcastSearchResult) -> Reason,
        limit: Int,
        rowLength: Int? = nil,
        authorShare: Double = 0.5,
        perAuthorCap: Int = 2
    ) -> [PodcastSearchResult] {
        guard limit > 0 else { return [] }
        func authorKey(_ r: PodcastSearchResult) -> String {
            r.author.flatMap { $0.isEmpty ? nil : $0.lowercased() } ?? r.title.lowercased()
        }
        var authorPool: [PodcastSearchResult] = []
        var genrePool: [PodcastSearchResult] = []
        var chartPool: [PodcastSearchResult] = []
        for r in list {
            switch reason(r) {
            case .sameAuthor: authorPool.append(r)
            case .genre: genrePool.append(r)
            case .popular: chartPool.append(r)
            }
        }
        var perAuthor: [String: Int] = [:]
        var out: [PodcastSearchResult] = []
        // The share is a share OF THE ROW, and the row is what a person
        // sees. `limit` is the length of the ORDERED LIST, which feeds
        // three surfaces at once and is five times longer. Measured against
        // it, `authorShare` handed out fifteen author seats for at most six
        // author cards, so the parameter decided nothing and the comment
        // above described a rule that was not running. `rowLength` is the
        // number the share belongs to; without one, list and row are the
        // same thing and the old reading is correct.
        let authorSeats = Int((Double(rowLength ?? limit) * authorShare).rounded())
        for r in authorPool where out.count < authorSeats {
            let key = authorKey(r)
            guard perAuthor[key, default: 0] < perAuthorCap else { continue }
            perAuthor[key, default: 0] += 1
            out.append(r)
        }
        // Fill: category first, charts last. The cap keeps counting.
        for r in genrePool + chartPool where out.count < limit {
            let key = authorKey(r)
            guard perAuthor[key, default: 0] < perAuthorCap else { continue }
            perAuthor[key, default: 0] += 1
            out.append(r)
        }
        // The row length is guaranteed: if the cap starved the fill, the
        // capped-out entries return in source order (a full row of second
        // ZEIT shows beats a short row. The cap orders, it never empties).
        if out.count < limit {
            let taken = Set(out.map { PodcastSubscriptions.normalizeFeedURL($0.feedURL) })
            for r in authorPool + genrePool + chartPool where out.count < limit {
                if !taken.contains(PodcastSubscriptions.normalizeFeedURL(r.feedURL)) {
                    out.append(r)
                }
            }
        }
        return out
    }

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

    /// Below this many category hits the generic chart fills up. The row
    /// must not stay half empty just because a category is thin.
    private static let minCategoryHits = 10

    /// How many cards the ROW shows. The artwork probe, the share witness
    /// and the author share all mean this same number; it stood three
    /// times as a literal, and the author share was the one place that
    /// used a different one by accident.
    static let shownRowLength = 6

    /// Remove from the list after subscribing.
    func remove(feedURL: String) {
        let n = PodcastSubscriptions.normalizeFeedURL(feedURL)
        results.removeAll { PodcastSubscriptions.normalizeFeedURL($0.feedURL) == n }
    }

    // MARK: - "Not interested"

    /// Permanently hidden recommendations. A dictionary so the RELEASE page
    /// can show a name, not a feed URL. Filtering happens in THIS store, whose
    /// results only ever feed the three recommendation surfaces: search,
    /// genre charts and links never ask here, so what the user actively
    /// steers to stays visible. The correction holds structurally.
    private static let hiddenKey = "podcastRecommendationsHidden"
    private(set) var hiddenByFeed: [String: String] = {
        (AppStorageKeys.dictionary(hiddenKey) as? [String: String]) ?? [:]
    }()

    /// "Not interested": out of all three surfaces at once, permanently.
    func hide(_ result: PodcastSearchResult) {
        let n = PodcastSubscriptions.normalizeFeedURL(result.feedURL)
        hiddenByFeed[n] = result.title
        AppStorageKeys.set(hiddenByFeed, for: Self.hiddenKey)
        results.removeAll { PodcastSubscriptions.normalizeFeedURL($0.feedURL) == n }
    }

    /// The release path (settings): the show may be recommended again.
    func unhide(normalizedFeed: String) {
        hiddenByFeed.removeValue(forKey: normalizedFeed)
        AppStorageKeys.set(hiddenByFeed, for: Self.hiddenKey)
        loadedAt = nil   // the next refresh may bring it back
        objectWillChange.send()
    }

    // MARK: - Signals from your own usage

    /// The SEED of the recommendations. Deliberately WITHOUT
    /// mirrored feeds. A Pinchflat capsule is a private mirror; feeding its
    /// author/categories into a PUBLIC catalog search produced the user'
    /// "because you listen to IDA" → Institute for Defense Analyses (four of
    /// six tiles were misses on a bare author string). Same capsule rule as
    /// in the gpodder sync: a mirror is not a subscription of the user's in
    /// the public sense. Filtering here covers authors, categories AND
    /// listening time at once. One place, not three.
    ///
    /// FOLDED per feed (product decision of 08.09.2026: do not count a
    /// show twice). The reason is not that a double entry is untidy, it is that
    /// the doubling is NOT evenly spread: a show subscribed in Mär while the
    /// server is active lands on ABS only and counts once, while a show that
    /// came from an import or gpodder gets mirrored to the server by
    /// `PodcastSubscriptionSync.reconcile` and then stands in BOTH pots. The
    /// seed therefore favoured exactly the imported shows over the ones
    /// subscribed here. A subset with a system in it, which is a bias and
    /// not noise.
    ///
    /// The source switch stays OUT of this on purpose: „do not show me this
    /// source" is not „forget what I heard there". The seed is not a display.
    ///
    /// The mirror filter asks the ADDRESS, not the copy. `origin` is only
    /// ever set on the local side (`PodcastSubscriptions.setOrigin`), ABS
    /// never sets it, and `reconcile` mirrors capsules to the server like
    /// anything else, so a mirrored capsule comes back as an ABS twin with
    /// no mark on it and used to walk straight past the per-copy filter into
    /// a PUBLIC catalog search. That is the leak the IDA incident above was
    /// about, one source further along.
    private var mineShows: [PodcastShow] { mineGroups.compactMap(\.first) }

    /// The same seed, but each feed with all its copies. The survivor is the
    /// first, the rest exist so that no listening time is lost when folding
    /// (see `PodcastShowMerge.liftingTwins`).
    private var mineGroups: [[PodcastShow]] {
        // On ONE line so the growth fence stays comparable: it counts lines
        // with a grip, and making two lines of one would have raised the
        // stock without a grip being added.
        PodcastShowMerge.seedGroups(abs: ABSPodcastProvider.shared.activeShows, rss: PodcastSubscriptions.shared.shows)
    }

    /// Listening time per show (proxy: sum of the stored `localPosition` seconds
    /// of all this show's episodes). Retroactive, without new tracking.
    /// Shared with the statistics surface. The same question gets the same
    /// answer, from `ListeningByClass`, instead of two derivations that could
    /// disagree on screen.
    private func listeningByShow() -> [String: Double] {
        ListeningByClass.shows(positions: ListeningStore.positions(),
                               showId: AppStorageKeys.podcastShowId(forEpisodeId:))
    }

    /// One show as the taste signal sees it. A subscription and a
    /// co-listened show differ ONLY in `share`, so the rules below cannot
    /// treat them as two kinds of thing.
    struct TasteShow: Sendable, Equatable {
        let id: String
        let author: String?
        let categories: [String]
        /// 1 for a subscription, 0.5 for a co-listened show.
        let share: Double
    }

    /// What the person's own usage says, in one list. A co-listened show
    /// (heard through, never followed) counts HALF, and only from its
    /// second episode on: hearing a show through says something about
    /// taste, following it says it twice, and one episode is a look
    /// (decided 07.09.2026). Nothing here subscribes to anything.
    private var tasteShows: [TasteShow] {
        var out = mineShows.map {
            TasteShow(id: $0.id, author: $0.author, categories: $0.categories ?? [], share: 1)
        }
        let qualifying = Set(CoListenedShows.current().filter(CoListened.countsForTaste).map(\.feedKey))
        guard !qualifying.isEmpty else { return out }
        for show in CoListenedShows.shows()
        where qualifying.contains(PodcastSubscriptions.normalizeFeedURL(show.feedURL)) {
            out.append(TasteShow(id: show.id, author: show.author,
                                 categories: show.categories ?? [],
                                 share: CoListened.tasteShare))
        }
        return out
    }

    /// Authors by listening time (most-listened first). Shows without listening
    /// time count with minimal weight so new subscriptions contribute too.
    nonisolated static func weightedAuthors(_ shows: [TasteShow],
                                            listening: [String: Double]) -> [String] {
        var weight: [String: Double] = [:]
        for show in shows {
            guard let author = show.author, !author.isEmpty else { continue }
            weight[author, default: 0] += ((listening[show.id] ?? 0) + 1) * show.share
        }
        return weight.sorted { $0.value > $1.value }.map { $0.key }
    }

    /// Categories weighted by listening time; broad categories only at 30 %.
    nonisolated static func weightedCategories(_ shows: [TasteShow],
                                               listening: [String: Double]) -> [String] {
        var weight: [String: Double] = [:]
        for show in shows {
            let base = ((listening[show.id] ?? 0) + 1) * show.share
            for c in show.categories {
                let factor = broadCategories.contains(c.lowercased()) ? 0.3 : 1.0
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

    /// REAL author equality, folded. The
    /// measured word-collision fix. Both old holes are gone: the TITLE branch
    /// ("Einschlafen" booked 25/25 foreign shows as sameAuthor. A title is
    /// no proof of authorship) and the two-way `contains` ("Sport" pulled
    /// Barstool/FOX Sports). An optional word-boundary prefix is NOT
    /// built: it would not cover the "DIE ZEIT"/"ZEIT ONLINE" pair either
    /// (neither prefixes the other), and equality keeps the row honest.
    /// A publisher variant surfaces via genre/charts with its own reason.
    private func authorMatches(_ r: PodcastSearchResult, _ author: String) -> Bool {
        Self.sameAuthor(r.author, anchor: author)
    }

    /// The one comparison, pure for the fences: folded equality of the
    /// author FIELDS, nothing else.
    nonisolated static func sameAuthor(_ candidate: String?, anchor: String) -> Bool {
        guard let candidate else { return false }
        let a = foldAuthor(candidate), b = foldAuthor(anchor)
        return !a.isEmpty && a == b
    }

    private nonisolated static func foldAuthor(_ raw: String) -> String {
        raw.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .lowercased()
            .map { $0.isLetter || $0.isNumber ? $0 : " " }
            .reduce(into: "") { out, ch in
                if ch == " ", out.hasSuffix(" ") { return }
                out.append(ch)
            }
            .trimmingCharacters(in: .whitespaces)
    }

    /// Author hits + category proximity as the base rank, then mix by
    /// round-robin across the authors (max 3 per author). So no publisher
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
        let shows = PodcastShowSources.ownedShows()
        let visible = Self.excludingSubscribed(
            list,
            subscribedNormalizedFeeds: PodcastShowMerge.normalizedFeeds(shows),
            subscribedTitles: shows.map(\.title))
        // Same mechanics as the subscribed filter, one more set.
        return visible.filter {
            hiddenByFeed[PodcastSubscriptions.normalizeFeedURL($0.feedURL)] == nil
        }
    }

    /// Pure (tested): drop already-subscribed feeds + duplicates, order kept.
    /// A subscribed show must never appear as a recommendation. The Home
    /// Discover row filters through this too (subscriptions can happen after
    /// the pool was built).
    ///
    /// The URL is not enough. The premium and the free variant of the
    /// SAME show live on different URLs (podcatcher vs. Simplecast), so the
    /// free twin of a premium subscription slipped through. Same for a
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
