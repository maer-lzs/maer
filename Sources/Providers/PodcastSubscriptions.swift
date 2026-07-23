// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Combine
import OSLog

/// Person from the feed (`<podcast:person>` / `itunes:owner`) — host/guest.
nonisolated struct PodcastPerson: Codable, Hashable {
    var name: String
    var role: String?
    var img: String?
    var href: String?
}

/// Support link of the show (`<podcast:funding>`).
nonisolated struct PodcastFunding: Codable, Hashable {
    var url: String
    var label: String?
}

/// A subscribed show with its episodes (persisted so the latest episodes stay
/// visible offline). New metadata fields are optional (`= nil`) so existing
/// saved feeds decode unchanged.
nonisolated struct PodcastShow: Codable, Identifiable {
    var id: String                 // stable feed id (derived from the URL)
    var title: String
    var author: String?
    var artworkURL: String?
    var description: String?
    var feedURL: String
    var episodes: [PodcastEpisode]
    // Rich metadata (RSS/Podcasting 2.0)
    var categories: [String]? = nil
    var link: String? = nil        // Website
    var language: String? = nil
    var explicit: Bool? = nil
    var funding: [PodcastFunding]? = nil
    var owner: String? = nil
    var showType: String? = nil    // episodic | serial
}

nonisolated struct PodcastEpisode: Codable, Identifiable {
    var guid: String
    var title: String
    var audioURL: String
    var pubDate: Double             // ms epoch
    var duration: Double            // seconds (0 if unknown)
    var description: String?
    var imageURL: String?
    /// Podcasting 2.0 chapters (`<podcast:chapters url=… type=json+chapters>`).
    /// Loaded only when opening the episode (RSSProvider.fetchItemDetail).
    var chaptersURL: String?
    // Rich metadata (optional → backward-compatible)
    var season: Int? = nil
    var episodeNumber: Int? = nil
    var episodeType: String? = nil // full | trailer | bonus
    var explicit: Bool? = nil
    var link: String? = nil
    var transcriptURL: String? = nil
    var persons: [PodcastPerson]? = nil

    var id: String { guid }
}

/// Management of podcast subscriptions: add/remove feeds, refresh (RSS/Atom via
/// XMLParser, no third-party dependency), persistent cache. Pure source backend
/// behind the `RSSProvider` — the core talks only to the provider, never
/// directly here (only the management UI does).
/// Y51: a just-subscribed premium feed looks like an existing free
/// subscription — offer to replace it (with progress takeover). Presented as a
/// QUESTION, never applied silently.
nonisolated struct PremiumReplacementOffer: Equatable {
    let freeShowId: String
    let premiumShowId: String
    let showTitle: String
}

@MainActor
final class PodcastSubscriptions: ObservableObject {
    static let shared = PodcastSubscriptions()

    @Published private(set) var shows: [PodcastShow] = [] {
        didSet { rebuildCaches() }
    }

    /// Y51: set when a new premium subscription matches an existing free one;
    /// the sources UI presents it as an alert. Cleared on accept/decline.
    @Published var pendingPremiumReplacement: PremiumReplacementOffer?

    /// guid → (show index, episode index) for O(1) lookup instead of a linear
    /// search over all episodes (which ran per cover cell and dragged after import).
    private var episodeIndex: [String: (show: Int, episode: Int)] = [:]
    /// Cached, sorted full list (invalidated on a `shows` change).
    private var cachedAllEpisodes: [(show: PodcastShow, episode: PodcastEpisode)]?

    private func rebuildCaches() {
        cachedAllEpisodes = nil
        episodeIndex = Self.buildEpisodeIndex(shows)
    }

    /// guid → (show index, episode index). Pure + static so tests can verify the
    /// index against fixtures.
    nonisolated static func buildEpisodeIndex(_ shows: [PodcastShow]) -> [String: (show: Int, episode: Int)] {
        var index: [String: (show: Int, episode: Int)] = [:]
        index.reserveCapacity(shows.reduce(0) { $0 + $1.episodes.count })
        for (s, show) in shows.enumerated() {
            for (e, ep) in show.episodes.enumerated() { index[ep.guid] = (s, e) }
        }
        return index
    }

    private let fileURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("podcast_subscriptions.json")

    /// Startup load. The full-store JSON decode used to run synchronously in
    /// init — on the main actor, BEFORE first paint (the singleton is created
    /// by the first observing view). The decode now runs off-main; the UI
    /// starts empty and fills one tick later. Startup callers that need the
    /// episode index (session restore, CarPlay) await `ensureLoaded()`.
    private var bootstrapTask: Task<Void, Never>?

    private init() {
        let url = fileURL
        bootstrapTask = Task { [weak self] in
            let decoded = await Task.detached(priority: .userInitiated) { () -> [PodcastShow] in
                guard let data = try? Data(contentsOf: url) else { return [] }
                return (try? JSONDecoder().decode([PodcastShow].self, from: data)) ?? []
            }.value
            guard let self, !decoded.isEmpty else { return }
            self.shows = self.migrated(decoded)
        }
    }

    /// Waits for the initial disk load (no-op once finished).
    func ensureLoaded() async {
        await bootstrapTask?.value
    }

    // MARK: - Serialized disk writes

    /// All writes to the store file are CHAINED (see `SerializedWriteChain`):
    /// encode+write run off-main, and each write awaits the previous one — two
    /// overlapping detached writes could otherwise interleave and corrupt the
    /// JSON. Writes take a value snapshot, so later mutations of `shows` don't
    /// affect an in-flight write.
    private let writeChain = SerializedWriteChain()

    private func persist(_ snapshot: [PodcastShow]) {
        writeChain.write(to: fileURL) {
            try? JSONEncoder().encode(snapshot)
        }
    }

    var hasSubscriptions: Bool { !shows.isEmpty }

    #if DEBUG
    /// UI-test seeding only (see UITestSeed) — injects deterministic shows.
    func _seedForUITest(_ shows: [PodcastShow]) { self.shows = shows }
    #endif

    // MARK: - Stable ids + dedup (migration)

    /// Deterministic key of a feed (FNV-1a hex over the normalised URL).
    /// Replaces the previously used `String.hashValue`, which was re-seeded on
    /// each app start and thus caused duplicates + progress loss.
    nonisolated static func feedKey(_ feedURL: String) -> String {
        stableHash(normalizeFeedURL(feedURL))
    }

    nonisolated static func stableHash(_ s: String) -> String {
        var h: UInt64 = 1469598103934665603          // FNV offset basis
        for b in s.utf8 { h = (h ^ UInt64(b)) &* 1099511628211 }   // FNV prime
        return String(h, radix: 16)
    }

    /// Make feed URLs comparable (scheme/`www.`/query/trailing slash ignored) so
    /// http/https or slash variants of the same feed collapse together.
    /// Dedup rule for Apple-import collisions on the same enclosure: played
    /// beats unplayed, then the further playhead wins.
    nonisolated static func isBetterAppleProgress(
        _ a: PodcastImport.AppleProgress, than b: PodcastImport.AppleProgress
    ) -> Bool {
        if a.isPlayed != b.isPlayed { return a.isPlayed }
        return a.playhead > b.playhead
    }

    /// Query parameters that carry feed IDENTITY — two URLs differing in one of
    /// these are DIFFERENT feeds (private tokens, CMS show selectors) and must
    /// not collapse into one subscription. Everything else (tracking params
    /// etc.) is still stripped.
    /// Y52: query parameters whose VALUES are access secrets — a feed carrying
    /// one is the token-URL premium class (access baked into the URL, no login).
    /// ONE source: the identity set below builds on this, no duplication.
    nonisolated static let secretQueryParams: Set<String> =
        ["token", "auth", "key", "secret"]

    nonisolated private static let identityQueryParams: Set<String> =
        secretQueryParams.union(["id", "show", "feed", "user", "podcast"])

    /// Y52: token-URL premium class — a known secret parameter with a non-empty
    /// value. Conservative string parse (works for raw AND normalized URLs).
    nonisolated static func isTokenFeedURL(_ raw: String) -> Bool {
        guard let q = raw.firstIndex(of: "?") else { return false }
        return raw[raw.index(after: q)...].split(separator: "&").contains { pair in
            let parts = pair.split(separator: "=", maxSplits: 1)
            return parts.count == 2 && !parts[1].isEmpty
                && secretQueryParams.contains(parts[0].lowercased())
        }
    }

    /// Provider-premium (Teil 5 cut): the comparable host of a feed URL —
    /// scheme/`www.` stripped, lowercased, up to the first path segment.
    nonisolated static func feedHost(_ raw: String) -> String {
        var s = raw.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        s = s.replacingOccurrences(of: "https://", with: "")
             .replacingOccurrences(of: "http://", with: "")
        if s.hasPrefix("www.") { s.removeFirst(4) }
        if let slash = s.firstIndex(where: { $0 == "/" || $0 == "?" }) { s = String(s[..<slash]) }
        return s
    }

    /// Y52: display/log-safe form — secret parameter values become "••••",
    /// everything else stays. Never show/log a token feed URL unmasked.
    nonisolated static func maskedFeedURL(_ raw: String) -> String {
        guard let q = raw.firstIndex(of: "?") else { return raw }
        let base = raw[..<q]
        let masked = raw[raw.index(after: q)...].split(separator: "&").map { pair -> String in
            let parts = pair.split(separator: "=", maxSplits: 1)
            guard parts.count == 2, secretQueryParams.contains(parts[0].lowercased()) else {
                return String(pair)
            }
            return "\(parts[0])=••••"
        }
        return base + "?" + masked.joined(separator: "&")
    }

    /// Known members-only feed hosts (moved here from the podcast tab so the
    /// premium test has ONE home).
    nonisolated private static let premiumHosts =
        ["patreon.com", "supercast", "supportingcast", "memberful", "acast.com/access"]

    /// THE premium test: stored basic-auth credentials OR the token-URL class
    /// OR a known members-only host. Used by the tab grouping and management.
    nonisolated static func isPremiumFeed(_ feedURL: String) -> Bool {
        if PodcastFeedAuth.hasCredentials(feedKey: feedKey(feedURL)) { return true }
        if isTokenFeedURL(feedURL) { return true }
        let lower = feedURL.lowercased()
        return premiumHosts.contains { lower.contains($0) }
    }

    nonisolated static func normalizeFeedURL(_ raw: String) -> String {
        var s = raw.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        var identityQuery = ""
        if let q = s.firstIndex(of: "?") {
            // Keep identity-relevant parameters (sorted, canonical) so feeds
            // that differ only in a token/show id stay distinct subscriptions;
            // drop the rest (tracking) as before.
            let query = String(s[s.index(after: q)...])
            let kept = query.split(separator: "&")
                .filter { pair in
                    let name = pair.split(separator: "=", maxSplits: 1)[0]
                    return identityQueryParams.contains(String(name))
                }
                .sorted()
            if !kept.isEmpty { identityQuery = "?" + kept.joined(separator: "&") }
            s = String(s[..<q])
        }
        s = s.replacingOccurrences(of: "https://", with: "")
             .replacingOccurrences(of: "http://", with: "")
        if s.hasPrefix("www.") { s.removeFirst(4) }
        while s.hasSuffix("/") { s.removeLast() }
        return s + identityQuery
    }

    /// Bring persisted shows to stable ids/guids and merge duplicate shows (same
    /// normalised feed URL). Idempotent — later starts change nothing. When
    /// re-keying the guids the associated `localPosition` progress moves along
    /// (old→new) so the just-imported Apple progress is preserved.
    private func migrated(_ decoded: [PodcastShow]) -> [PodcastShow] {
        let (result, changed) = Self.migrate(decoded, moveProgress: Self.migrateLocalPosition)
        if changed {
            // Write back (serialized, off-main) so the cleanup is persistent.
            persist(result)
        }
        return result
    }

    /// Pure migration core (testable): re-key ids/guids, report every progress
    /// move via `moveProgress(old, new)`, dedupe shows of the same feed.
    nonisolated static func migrate(
        _ decoded: [PodcastShow],
        moveProgress: (String, String) -> Void
    ) -> (shows: [PodcastShow], changed: Bool) {
        var byKey: [String: PodcastShow] = [:]
        var order: [String] = []
        var changed = false

        for show in decoded {
            let key = feedKey(show.feedURL)
            var rebuilt = show
            rebuilt.id = "feed:\(key)"
            if rebuilt.id != show.id { changed = true }
            rebuilt.episodes = show.episodes.map { ep in
                var e = ep
                let newGuid = "rss:\(key):\(originalGuid(ep.guid))"
                if newGuid != ep.guid {
                    moveProgress(ep.guid, newGuid)
                    e.guid = newGuid
                    changed = true
                }
                return e
            }

            if let existing = byKey[key] {
                byKey[key] = merge(existing, rebuilt)
                changed = true
            } else {
                byKey[key] = rebuilt
                order.append(key)
            }
        }

        return (order.compactMap { byKey[$0] }, changed)
    }

    /// Extract the original guid from `rss:<hash>:<original>` (which may itself
    /// contain colons → maxSplits 2).
    private nonisolated static func originalGuid(_ guid: String) -> String {
        let parts = guid.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false)
        if parts.count == 3, parts[0] == "rss" { return String(parts[2]) }
        return guid
    }

    /// Merge two shows of the same feed: keep the metadata of the richer one,
    /// deduplicate episodes by guid, newest first.
    /// Union two versions of a show by episode GUID, keeping the richer set and
    /// losing nothing — the base is whichever already has more episodes. `internal`
    /// so the RSS hardening (never shrink on a weak fetch) is unit-testable.
    nonisolated static func merge(_ a: PodcastShow, _ b: PodcastShow) -> PodcastShow {
        let (base, other) = a.episodes.count >= b.episodes.count ? (a, b) : (b, a)
        var result = base
        var seen = Set(base.episodes.map { $0.guid })
        let extra = other.episodes.filter { seen.insert($0.guid).inserted }
        result.episodes = (base.episodes + extra).sorted { $0.pubDate > $1.pubDate }
        return result
    }

    /// Move `localPosition.<oldGuid>` → `<newGuid>` (only if the target is empty).
    private nonisolated static func migrateLocalPosition(from old: String, to new: String) {
        let d = UserDefaults.standard
        let oldKey = AppStorageKeys.localPosition(old)
        let newKey = AppStorageKeys.localPosition(new)
        guard d.object(forKey: newKey) == nil, let value = d.array(forKey: oldKey) else { return }
        d.set(value, forKey: newKey)
        d.removeObject(forKey: oldKey)
    }

    // MARK: - Subscriptions

    /// Subscribe to a feed (loads + parses immediately). Already-present feeds
    /// are only refreshed.
    func subscribe(urlString: String) async -> Bool {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = normalizedFeedURL(trimmed) else { return false }
        guard let show = await Self.fetchAndParse(feedURL: url) else { return false }
        if let idx = shows.firstIndex(where: { $0.id == show.id }) {
            // Re-subscribe must not blindly replace: a weak parse (valid title,
            // few/zero episodes) would drop the cached episodes. Union instead.
            shows[idx] = Self.merge(shows[idx], show)
        } else {
            shows.insert(show, at: 0)
            // Y51: a NEW premium feed (credentials stored for its feedKey) that
            // looks like an existing credential-free subscription → offer the
            // replacement. Conservative same-show test; the user decides.
            if PodcastFeedAuth.hasCredentials(feedKey: Self.feedKey(show.feedURL)),
               let free = shows.first(where: {
                   $0.id != show.id
                       && !PodcastFeedAuth.hasCredentials(feedKey: Self.feedKey($0.feedURL))
                       && PodcastPremiumMatch.sameShow(titleA: $0.title, titleB: show.title)
               }) {
                pendingPremiumReplacement = PremiumReplacementOffer(
                    freeShowId: free.id, premiumShowId: show.id, showTitle: show.title)
            }
        }
        save()
        return true
    }

    /// Y51 accept path: move the matched episodes' local progress free→premium
    /// (the migrateLocalPosition pattern: target-empty guard), adopt their
    /// downloads, then unsubscribe the free show. Unmatched free episodes keep
    /// nothing to lose — their progress keys simply become orphaned history.
    @discardableResult
    func replaceFreeWithPremium(_ offer: PremiumReplacementOffer) -> (progressMoved: Int, downloadsAdopted: Int) {
        defer { pendingPremiumReplacement = nil }
        guard let free = shows.first(where: { $0.id == offer.freeShowId }),
              let premium = shows.first(where: { $0.id == offer.premiumShowId }) else { return (0, 0) }
        let matches = PodcastPremiumMatch.episodeMatches(free: free.episodes, premium: premium.episodes)
        var moved = 0
        var adopted = 0
        let defaults = UserDefaults.standard
        for (freeGuid, premiumGuid) in matches {
            if defaults.object(forKey: AppStorageKeys.localPosition(freeGuid)) != nil {
                Self.migrateLocalPosition(from: freeGuid, to: premiumGuid)
                moved += 1
            }
            if DownloadManager.shared.adoptDownload(from: freeGuid, to: premiumGuid) {
                adopted += 1
            }
        }
        unsubscribe(id: free.id)
        PodcastProgressStore.shared.reload()
        // Regel 3: the takeover is visible in the log (titles only, no URLs —
        // premium URLs can carry secrets).
        Logger.rss.notice("premium replacement: \(offer.showTitle, privacy: .public) — \(matches.count) matched, \(moved) progress moved, \(adopted) downloads adopted")
        return (moved, adopted)
    }

    func unsubscribe(id: String) {
        shows.removeAll { $0.id == id }
        save()
    }

    /// Load a show's full history via PodcastIndex (if a key is set) and merge
    /// it into the persisted episodes. Same `rss:<feedKey>:<guid>` ids as the
    /// feed → dedup + shared progress key. Returns: number of NEW episodes added.
    func loadFullHistory(showId: String) async -> Int {
        guard AppStorageKeys.podcastIndexConfigured,
              let idx = shows.firstIndex(where: { $0.id == showId }) else { return 0 }
        let show = shows[idx]
        let dir = PodcastIndexDirectory(
            key: AppStorageKeys.podcastIndexKeyValue,
            secret: AppStorageKeys.podcastIndexSecretValue
        )
        guard let piEpisodes = try? await dir.episodes(feedURL: show.feedURL) else { return 0 }
        let key = Self.feedKey(show.feedURL)
        var seen = Set(show.episodes.map { $0.guid })
        var added: [PodcastEpisode] = []
        for pi in piEpisodes {
            guard let audio = pi.enclosureUrl, !audio.isEmpty else { continue }
            let guid = "rss:\(key):\(pi.guid ?? audio)"   // like RSSFeedParser
            guard seen.insert(guid).inserted else { continue }
            added.append(PodcastEpisode(
                guid: guid,
                title: pi.title ?? String(localized: "Untitled Episode"),
                audioURL: audio,
                pubDate: (pi.datePublished ?? 0) * 1000,
                duration: pi.duration ?? 0,
                description: pi.description,
                imageURL: pi.image
            ))
        }
        guard !added.isEmpty else { return 0 }
        shows[idx].episodes = (show.episodes + added).sorted { $0.pubDate > $1.pubDate }
        save()
        return added.count
    }

    // MARK: - Import (OPML / Apple Podcasts)

    /// Result of an import for UI feedback.
    struct ImportResult {
        var subscribed = 0        // newly/refreshed subscribed
        var failed = 0            // feed not loadable
        var progressApplied = 0   // episodes with applied progress/played
        var paidSkipped = 0       // S21: paid/exclusive subs without a public feed
    }

    /// Import an OPML file: subscribe to every `xmlUrl` feed (no progress).
    func importOPML(_ data: Data) async -> ImportResult {
        var result = ImportResult()
        for feed in PodcastImport.parseOPML(data) {
            if await subscribe(urlString: feed) { result.subscribed += 1 } else { result.failed += 1 }
        }
        return result
    }

    /// Import Apple Podcasts `MTLibrary.sqlite`: subscriptions + progress + played.
    /// `nil` if the file cannot be opened as SQLite.
    func importAppleLibrary(at url: URL) async -> ImportResult? {
        // Move the SQLite read off the MainActor (can take a while for a large
        // DB); the calling view's security-scoped access applies process-wide.
        guard let library = await Task.detached(priority: .userInitiated, operation: {
            PodcastImport.readAppleLibrary(at: url)
        }).value else { return nil }
        var result = ImportResult()
        for feed in library.feedURLs {
            if await subscribe(urlString: feed) { result.subscribed += 1 } else { result.failed += 1 }
        }
        result.progressApplied = applyAppleProgress(library.progress)
        result.paidSkipped = library.unimportablePaidCount
        return result
    }

    /// Maps Apple's enclosure URLs to our episodes and writes their progress
    /// into `localPosition` (the same store the player uses).
    private func applyAppleProgress(_ progress: [PodcastImport.AppleProgress]) -> Int {
        guard !progress.isEmpty else { return 0 }
        // Index by normalized enclosure URL (query/scheme don't matter). On a
        // collision keep the BETTER entry (played beats unplayed, then the
        // further playhead) — "last in array wins" could keep the worse state.
        var byURL: [String: PodcastImport.AppleProgress] = [:]
        for p in progress {
            let key = Self.normalizeEnclosure(p.enclosureURL)
            if let existing = byURL[key], !Self.isBetterAppleProgress(p, than: existing) { continue }
            byURL[key] = p
        }

        var updated = shows
        var applied = 0
        for s in updated.indices {
            for e in updated[s].episodes.indices {
                let episode = updated[s].episodes[e]
                guard let match = byURL[Self.normalizeEnclosure(episode.audioURL)] else { continue }
                // If the feed lacks the duration (no `itunes:duration`), take
                // Apple's — otherwise "played" (time ≥ duration−1) can never apply.
                if episode.duration <= 0, match.duration > 0 {
                    updated[s].episodes[e].duration = match.duration
                }
                let duration = updated[s].episodes[e].duration
                let time = match.isPlayed ? max(duration, match.playhead) : match.playhead
                guard time > 1 else { continue }
                UserDefaults.standard.set(
                    [time, Date().timeIntervalSince1970 * 1000],
                    forKey: AppStorageKeys.localPosition(episode.guid)
                )
                applied += 1
            }
        }
        if applied > 0 {
            shows = updated   // adopt possibly corrected durations (didSet rebuilds the index)
            save()
            PodcastProgressStore.shared.reload()
        }
        return applied
    }

    /// Make enclosure URLs comparable: drop query & scheme, lowercase, trim /.
    nonisolated static func normalizeEnclosure(_ raw: String) -> String {
        var s = raw.lowercased()
        if let q = s.firstIndex(of: "?") { s = String(s[..<q]) }
        s = s.replacingOccurrences(of: "https://", with: "")
             .replacingOccurrences(of: "http://", with: "")
        while s.hasSuffix("/") { s.removeLast() }
        return s
    }

    /// Adopt the real asset duration measured by the player — feeds often omit
    /// or round `itunes:duration`, and without a duration the played/remaining
    /// state cannot be derived. Persisted so lists and play-state math work
    /// from then on.
    func updateEpisodeDuration(guid: String, duration: Double) {
        guard duration > 0, duration.isFinite, let idx = episodeIndex[guid] else { return }
        guard abs(shows[idx.show].episodes[idx.episode].duration - duration) > 1 else { return }
        shows[idx.show].episodes[idx.episode].duration = duration
        save()
    }

    /// Reload all feeds (pull-to-refresh). Failed ones keep their cached state.
    func refreshAll() async {
        // TF bib-toggles: RSS source off (podcast tab ∧ RSS toggle) → no feed
        // fetches from any caller (background refresh, tab load, pull-to-refresh).
        // THE one gate for the bulk RSS refresh; deliberate user actions
        // (subscribe/preview) stay ungated.
        guard AppStorageKeys.rssActive else { return }
        var updated = shows
        for (index, show) in shows.enumerated() {
            if let url = URL(string: show.feedURL), let fresh = await Self.fetchAndParse(feedURL: url) {
                // Never shrink on a single weak fetch: a parse that returns a
                // valid title but far fewer episodes (server hiccup, empty but
                // valid <channel>) would otherwise wipe the cached episode list.
                // Union keeps everything; more episodes still add normally.
                #if DEBUG
                if fresh.episodes.count * 2 < show.episodes.count {
                    Logger.rss.debug("RSS refresh shrank \(show.title, privacy: .public): cached=\(show.episodes.count) fresh=\(fresh.episodes.count) → union keeps the cache")
                }
                #endif
                updated[index] = Self.merge(show, fresh)
            }
            // Pro-Show-Limit anwenden (News-Shows schlank halten).
            applyLimit(&updated[index], keepLatest: AppStorageKeys.podcastEpisodeLimitValue(updated[index].id))
        }
        shows = updated
        save()
    }

    /// Trim to the latest N episodes (0 = unlimited) and discard downloads of
    /// the removed episodes. Directly from the per-show settings.
    func trimEpisodes(showId: String, keepLatest n: Int) async {
        guard let idx = shows.firstIndex(where: { $0.id == showId }) else { return }
        if applyLimit(&shows[idx], keepLatest: n) { save() }
    }

    @discardableResult
    private func applyLimit(_ show: inout PodcastShow, keepLatest n: Int) -> Bool {
        guard n > 0 else { return false }
        let sorted = show.episodes.sorted { $0.pubDate > $1.pubDate }
        guard sorted.count > n else { return false }
        for ep in sorted.dropFirst(n) { DownloadManager.shared.deleteDownload(itemId: ep.guid) }
        show.episodes = Array(sorted.prefix(n))
        return true
    }

    // MARK: - Queries for the provider

    /// All episodes of all shows, newest first (cached — otherwise re-sorted
    /// several times per render).
    func allEpisodes() -> [(show: PodcastShow, episode: PodcastEpisode)] {
        if let cached = cachedAllEpisodes { return cached }
        let all = shows.flatMap { show in show.episodes.map { (show: show, episode: $0) } }
            .sorted { $0.episode.pubDate > $1.episode.pubDate }
        cachedAllEpisodes = all
        return all
    }

    /// O(1) lookup via the guid index.
    func episode(guid: String) -> (show: PodcastShow, episode: PodcastEpisode)? {
        guard let (s, e) = episodeIndex[guid],
              s < shows.count, e < shows[s].episodes.count else { return nil }
        return (shows[s], shows[s].episodes[e])
    }

    // MARK: - Persistenz

    /// Persist the current store (serialized, off-main — see `persist`). The
    /// old implementation encoded and wrote the whole JSON synchronously on the
    /// main actor: a visible hitch on subscribe/refresh/import.
    private func save() {
        persist(shows)
    }

    private func normalizedFeedURL(_ raw: String) -> URL? {
        var s = raw
        if !s.hasPrefix("http://") && !s.hasPrefix("https://") { s = "https://" + s }
        return URL(string: s)
    }

    // MARK: - Loading + Parsing

    // `@concurrent`: force this off the caller's executor. Under the project's
    // default MainActor isolation + NonisolatedNonsendingByDefault a plain
    // `nonisolated async` would run the network wait AND the XML parse on the
    // calling MainActor (callers at :284/:436 are main-actor). The parse is CPU
    // work that must not block the UI.
    /// Y2b: fetch + parse a feed WITHOUT persisting anything — the temporary
    /// show preview uses this; `subscribe` persists the result.
    @concurrent nonisolated static func fetchAndParse(feedURL: URL) async -> PodcastShow? {
        // Private/premium feeds: send the Basic auth header if stored.
        var request = URLRequest(url: feedURL)
        for (field, value) in PodcastFeedAuth.authHeader(feedKey: feedKey(feedURL.absoluteString)) {
            request.setValue(value, forHTTPHeaderField: field)
        }
        // Y39: feed pulls ride the same retry policy as the ABS/Subsonic
        // clients (transient backoff, 401 probe for private feeds); a non-2xx
        // that survives the policy stays a nil result like before.
        guard let (data, http) = try? await RequestRetryPolicy.fetch(request) else { return nil }
        if let status = http?.statusCode, !(200...299).contains(status) { return nil }
        let parser = RSSFeedParser(feedURL: feedURL.absoluteString)
        return parser.parse(data)
    }
}

/// Minimal RSS/Atom parser based on `XMLParser`. Covers the iTunes podcast
/// fields; unknown tags are ignored, broken items skipped. Internal (not
/// private) — covered by unit tests. `nonisolated`: pure CPU parsing, driven
/// off the main actor from `fetchAndParse` (@concurrent) and from tests.
nonisolated final class RSSFeedParser: NSObject, XMLParserDelegate {
    private let feedURL: String
    /// Stable, deterministic feed key (NOT `String.hashValue`, which is
    /// re-seeded per app start) — basis for show id and guids.
    private let feedKey: String
    init(feedURL: String) {
        self.feedURL = feedURL
        self.feedKey = PodcastSubscriptions.feedKey(feedURL)
    }

    private var showTitle = ""
    private var showAuthor: String?
    private var showImage: String?
    private var showDescription: String?
    // Show-Metadaten (Podcasting 2.0 / iTunes)
    private var showCategories: [String] = []
    private var showLink: String?
    private var showLanguage: String?
    private var showExplicit: Bool?
    private var showFunding: [PodcastFunding] = []
    private var showOwner: String?
    private var showType: String?
    private var pendingFundingURL: String?

    private var episodes: [PodcastEpisode] = []
    private var inItem = false
    private var text = ""

    // Aktuelles Item
    private var iTitle = "", iGuid = "", iAudio = "", iDuration = "", iDesc = "", iImage = "", iPubDate = "", iChapters = ""
    private var iSeason: Int?, iEpisodeNum: Int?, iEpisodeType = "", iExplicit: Bool?, iLink = "", iTranscript = ""
    private var iPersons: [PodcastPerson] = []
    private var pendingPersonAttrs: [String: String]?

    func parse(_ data: Data) -> PodcastShow? {
        let parser = XMLParser(data: data)
        parser.delegate = self
        guard parser.parse(), !showTitle.isEmpty || !episodes.isEmpty else { return nil }
        return PodcastShow(
            id: "feed:\(feedKey)",
            title: showTitle.isEmpty ? feedURL : showTitle,
            author: showAuthor,
            artworkURL: showImage,
            description: showDescription,
            feedURL: feedURL,
            episodes: episodes,
            categories: showCategories.isEmpty ? nil : showCategories,
            link: showLink,
            language: showLanguage,
            explicit: showExplicit,
            funding: showFunding.isEmpty ? nil : showFunding,
            owner: showOwner,
            showType: showType
        )
    }

    func parser(_ parser: XMLParser, didStartElement el: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes attrs: [String: String]) {
        text = ""
        if el == "item" || el == "entry" {
            inItem = true
            iTitle = ""; iGuid = ""; iAudio = ""; iDuration = ""; iDesc = ""; iImage = ""; iPubDate = ""; iChapters = ""
            iSeason = nil; iEpisodeNum = nil; iEpisodeType = ""; iExplicit = nil; iLink = ""; iTranscript = ""
            iPersons = []
        }
        // Podcasting 2.0 chapters: JSON URL in the item (use JSON type only).
        if el == "podcast:chapters", let url = attrs["url"],
           (attrs["type"]?.contains("json") ?? true) {
            iChapters = url
        }
        // Transcript (the first URL is enough).
        if el == "podcast:transcript", inItem, iTranscript.isEmpty, let url = attrs["url"] {
            iTranscript = url
        }
        // Person (name follows as text content) — remember the attributes now.
        if el == "podcast:person" { pendingPersonAttrs = attrs }
        // Funding (label follows as text) — remember the URL.
        if el == "podcast:funding" { pendingFundingURL = attrs["url"] }
        // Categories (also nested: parent + child both fire).
        if el == "itunes:category", !inItem, let cat = attrs["text"], !showCategories.contains(cat) {
            showCategories.append(cat)
        }
        // Enclosure (RSS) or media/link with audio type
        if el == "enclosure", let url = attrs["url"], (attrs["type"]?.hasPrefix("audio") ?? true) {
            iAudio = url
        }
        // itunes:image / channel image via href-Attribut
        if el == "itunes:image", let href = attrs["href"] {
            if inItem { iImage = href } else if showImage == nil { showImage = href }
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }

    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        if let s = String(data: CDATABlock, encoding: .utf8) { text += s }
    }

    func parser(_ parser: XMLParser, didEndElement el: String, namespaceURI: String?, qualifiedName qName: String?) {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // Closing a person (name = text content) — possible in item and channel.
        if el == "podcast:person", let a = pendingPersonAttrs, !value.isEmpty {
            let person = PodcastPerson(name: value, role: a["role"], img: a["img"], href: a["href"])
            if inItem { iPersons.append(person) }
            pendingPersonAttrs = nil
        }
        if el == "podcast:funding", !inItem, let url = pendingFundingURL {
            showFunding.append(PodcastFunding(url: url, label: value.isEmpty ? nil : value))
            pendingFundingURL = nil
        }
        if inItem {
            switch el {
            case "title": iTitle = value
            case "guid", "id": if iGuid.isEmpty { iGuid = value }
            case "itunes:duration": iDuration = value
            case "description", "itunes:summary", "content:encoded": if iDesc.isEmpty { iDesc = value }
            case "pubDate", "published": iPubDate = value
            case "itunes:season": iSeason = Int(value)
            case "itunes:episode": iEpisodeNum = Int(value)
            case "itunes:episodeType": iEpisodeType = value.lowercased()
            case "itunes:explicit": iExplicit = Self.parseExplicit(value)
            case "link": if iLink.isEmpty { iLink = value }
            case "item", "entry":
                inItem = false
                if !iAudio.isEmpty {
                    episodes.append(PodcastEpisode(
                        guid: "rss:\(feedKey):\(iGuid.isEmpty ? iAudio : iGuid)",
                        title: iTitle.isEmpty ? String(localized: "Untitled Episode") : iTitle,
                        audioURL: iAudio,
                        pubDate: Self.parseDate(iPubDate),
                        duration: Self.parseDuration(iDuration),
                        description: iDesc.isEmpty ? nil : iDesc,
                        imageURL: iImage.isEmpty ? nil : iImage,
                        chaptersURL: iChapters.isEmpty ? nil : iChapters,
                        season: iSeason,
                        episodeNumber: iEpisodeNum,
                        episodeType: iEpisodeType.isEmpty ? nil : iEpisodeType,
                        explicit: iExplicit,
                        link: iLink.isEmpty ? nil : iLink,
                        transcriptURL: iTranscript.isEmpty ? nil : iTranscript,
                        persons: iPersons.isEmpty ? nil : iPersons
                    ))
                }
            default: break
            }
        } else {
            switch el {
            case "title": if showTitle.isEmpty { showTitle = value }
            case "itunes:author": showAuthor = value
            case "description", "itunes:summary": if showDescription == nil { showDescription = value }
            case "link": if showLink == nil, !value.isEmpty { showLink = value }
            case "language": if showLanguage == nil { showLanguage = value }
            case "itunes:explicit": if showExplicit == nil { showExplicit = Self.parseExplicit(value) }
            case "itunes:type": showType = value.lowercased()
            case "itunes:name": if showOwner == nil, !value.isEmpty { showOwner = value }
            default: break
            }
        }
        text = ""
    }

    // RFC822-Datum → ms epoch (Fallback: 0).
    private static let rfc822: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
        return f
    }()

    private static func parseDate(_ s: String) -> Double {
        if let d = rfc822.date(from: s) { return d.timeIntervalSince1970 * 1000 }
        if let d = ISO8601DateFormatter().date(from: s) { return d.timeIntervalSince1970 * 1000 }
        return 0
    }

    /// `itunes:explicit`: true/yes/explicit → true, false/no/clean → false, else nil.
    private static func parseExplicit(_ s: String) -> Bool? {
        switch s.lowercased() {
        case "true", "yes", "explicit": return true
        case "false", "no", "clean": return false
        default: return nil
        }
    }

    // "HH:MM:SS", "MM:SS" or plain seconds → seconds.
    private static func parseDuration(_ s: String) -> Double {
        if s.contains(":") {
            let parts = s.split(separator: ":").compactMap { Double($0) }
            return parts.reduce(0) { $0 * 60 + $1 }
        }
        return Double(s) ?? 0
    }
}
