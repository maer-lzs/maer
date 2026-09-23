// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation
import Combine
import OSLog



/// Management of podcast subscriptions: add/remove feeds, refresh (RSS/Atom via
/// XMLParser, no third-party dependency), persistent cache. Pure source backend
/// behind the `RSSProvider`. The core talks only to the provider, never
/// directly here (only the management UI does).
/// A just-subscribed premium feed looks like an existing free
/// subscription. Offer to replace it (with progress takeover). Presented as a
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
        didSet {
            rebuildCaches()
            // A subscription that arrives (import, account adoption, the
            // person's own subscribe) changes what the episode rows show.
            ListeningRevision.shared.bump("subscriptions")
        }
    }

    /// Set when a new premium subscription matches an existing free one;
    /// the sources UI presents it as an alert. Cleared on accept/decline.
    @Published var pendingPremiumReplacement: PremiumReplacementOffer?
    /// The title of a feed that was just subscribed and brought no episode.
    /// Set by `subscribe`, consumed by the ONE host that shows it. Here and
    /// not in the three subscribe surfaces, because the store is the only
    /// place that knows what the parse yielded, and because there ARE three
    /// surfaces (settings page, cards, catalog page) and the message must
    /// exist once. Same shape as `pendingPremiumReplacement` above.
    @Published var emptyFeedNotice: String?

    /// Feeds from the account this device could not follow yet (feed key
    /// ⇒ address and reason). The Podcasts tab shows them with the reason;
    /// the adoption skips them until the person retries, signs in or
    /// removes them.
    @Published private(set) var feedsNotFollowed: [String: FeedAdoptionPending.Entry] = FeedAdoptionPending.pending()

    /// Test seam: replaces the network fetch of the adoption path.
    var _testFeedFetcher: ((URL) async -> FeedFetchOutcome)?

    /// guid → (show index, episode index) for O(1) lookup instead of a linear
    /// search over all episodes (which ran per cover cell and dragged after import).
    private var episodeIndex: [String: (show: Int, episode: Int)] = [:]
    /// Cached, sorted full list (invalidated on a `shows` change).
    private var cachedAllEpisodes: [(show: PodcastShow, episode: PodcastEpisode)]?

    private func rebuildCaches() {
        cachedAllEpisodes = nil
        episodeIndex = Self.buildEpisodeIndex(shows)
        // Mirror the origin-carrying feed keys into the defaults
        // set the nonisolated premium truth reads. ONE maintenance point,
        // always in sync with the store (bootstrap heals existing stores).
        let mirrored = Set(shows.filter { $0.origin != nil }.map { Self.feedKey($0.feedURL) })
        if mirrored != Self.mirroredFeedKeys() {
            AppStorageKeys.set(Array(mirrored).sorted(), for: AppStorageKeys.pinchflatMirroredFeedKeys)
        }
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
    /// init. On the main actor, BEFORE first paint (the singleton is created
    /// by the first observing view). The decode now runs off-main; the UI
    /// starts empty and fills one tick later. Startup callers that need the
    /// episode index (session restore, CarPlay) await `ensureLoaded()`.
    private var bootstrapTask: Task<Void, Never>?

    /// True once the bootstrap disk load finished (EVERY path).
    /// Save() refuses to persist before that, so a cold-start mutation can
    /// never wipe the good file with the still-empty in-memory state.
    private(set) var isLoaded = false

    private init() {
        let url = fileURL
        // The subscription family of the choice sync reads the list through
        // the store and hands adopted statements back to it.
        UserChoiceCloudSync.shared.localSubscriptions = { [weak self] in self?.subscriptionsForCloud() }
        UserChoiceCloudSync.shared.subscriptionAdopter = { [weak self] added, removed in
            self?.adoptCloudSubscriptions(added: added, removed: removed)
        }
        bootstrapTask = Task { [weak self] in
            // The rows are the stock. The document is read only when the
            // rows hold nothing: the first start after the move (then it is
            // poured into the rows once and set aside as .migrated), or a
            // fresh install (then it is missing and reads as empty).
            // The document's facts, read BEFORE a move sets it aside, so the
            // diagnosis line below describes what the start found.
            let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
            let size = (attrs?[.size] as? Int) ?? 0
            let mtime = (attrs?[.modificationDate] as? Date)?.description ?? "-"
            let rows = await self?.openRows()
            var decoded: [PodcastShow]? = nil
            var source = "rows"
            // What the rows hold after the start: known (read), fresh (read,
            // nothing there) or unknown (could not open or read). Unknown
            // rows are never replaced whole; the first write upserts only.
            var base: RowBase<[PodcastShow]> = rows == nil ? .unknown : .fresh
            if let rows {
                do {
                    // Two stages: the show list first (heads, no episodes:
                    // measured 1 ms at 300 shows), so the tab has its list
                    // while the episodes (530 ms at 75000, off the main
                    // actor) still decode. Writers wait for the whole task
                    // (`ensureLoaded`), so nothing lands between the stages.
                    let started = Date()
                    let heads = try await rows.loadHeads()
                    if !heads.isEmpty, let self {
                        self.shows = self.migrated(heads)
                        let headsMs = Int(Date().timeIntervalSince(started) * 1000)
                        let (loaded, skipped) = try await rows.loadAllCounted()
                        Logger.rss.notice("SUBROWS start: heads=\(heads.count) in \(headsMs) ms, episodes=\(loaded.reduce(0) { $0 + $1.episodes.count }) skipped=\(skipped) in \(Int(Date().timeIntervalSince(started) * 1000)) ms")
                        if !loaded.isEmpty { decoded = loaded }
                        // Rows that did not decode make the rows unknown,
                        // never fresh; the document is not poured over them.
                        base = RowBase.afterLoad(rows: loaded.isEmpty ? nil : loaded, skipped: skipped)
                    } else {
                        // No heads: the rows may still hold rows nobody can
                        // read. Count them before calling the rows empty.
                        let (_, skipped) = try await rows.loadAllCounted()
                        if skipped > 0 { base = .unknown }
                    }
                } catch {
                    base = .unknown
                    Logger.rss.error("SUBROWS load failed reason=\(String(describing: error), privacy: .public) fallback=migrated")
                }
            }
            if decoded == nil {
                source = "document"
                // "file missing" (fresh install) and "file present
                // but UNDECODABLE" (corruption) must not look the same. The old
                // ?? [] made a corrupt store start empty, and the NEXT persist()
                // silently overwrote the recoverable data with that empty list.
                // A corrupt file is preserved as .corrupt and loudly logged.
                // Through the seam: missing reads as fresh (empty list),
                // unreadable is kept aside as .corrupt and reads as nil.
                decoded = await {
                    switch await Ablage(directory: url.deletingLastPathComponent())
                        .load([PodcastShow].self, name: url.lastPathComponent) {
                    case .fresh: return []
                    case .loaded(let shows): return shows
                    case .corrupt: return nil
                    }
                }()
                if decoded == nil {
                    Logger.rss.error("subscriptions store undecodable — preserved as .corrupt, starting empty")
                }
                if case .unknown = base {
                    // The rows could not be read, or hold rows nobody can
                    // read (not: hold nothing). This run reads the document
                    // that was set aside, once, and migrates nothing; the
                    // rows heal on the next open.
                    if decoded?.isEmpty ?? true,
                       let aside = await Ablage(directory: url.deletingLastPathComponent())
                        .load([PodcastShow].self, name: url.lastPathComponent + ".migrated").value,
                       !aside.isEmpty {
                        decoded = aside
                        source = "migrated"
                    }
                } else if let rows, let stock = decoded, !stock.isEmpty {
                    if await Self.migrateDocument(at: url, stock: stock, into: rows) {
                        base = .known(stock)
                    }
                }
            }
            // Startup diagnosis. A future loss must be READABLE
            // from the log, not reconstructed.
            let corruptExists = FileManager.default.fileExists(atPath: url.appendingPathExtension("corrupt").path)
            Logger.rss.notice("SUBSTORE bootstrap: source=\(source, privacy: .public) size=\(size)B mtime=\(mtime, privacy: .public) shows=\(decoded?.count ?? -1) corruptBackup=\(corruptExists)")
            defer { self?.isLoaded = true }   // EVERY exit path unlocks save()
            self?.rowBase = base
            guard let self, let decoded, !decoded.isEmpty else { return }
            self.shows = self.migrated(decoded)
            // What the rows hold now, so the first change after the start is
            // a diff against the loaded stock and not a full write.
            if case .known = base { self.rowBase = .known(self.shows) }
            // Listen log: one-time backfill so the history of the CURRENT
            // subscriptions survives later unsubscribes/rotation.
            PodcastListenLog.shared.backfillIfNeeded(shows: self.shows)
            // The stock repair also runs at START, not only after a refresh:
            // measured on a device, `refreshAll` is reached by the background
            // task and the pull gesture alone. A user who imports and only
            // looks would never trigger it. It runs HERE, inside the load
            // task after the stock is set, so it can never see an empty
            // stock and pass as a sham run.
            self.healStoredProgress()
        }
    }

    /// Waits for the initial disk load (no-op once finished).
    /// Best-effort: the feed URL of the show owning this episode guid (for
    /// the show-independent listen log).
    /// The feed address of an episode: from the subscriptions, else from
    /// the browsed halves (a listened episode of a show nobody subscribed to
    /// still has an address; the listen log used to get "" for it).
    func feedURL(forEpisodeId episodeId: String) -> String? {
        shows.first { $0.episodes.contains { $0.guid == episodeId } }?.feedURL
            ?? BrowsedEpisodes.shared.episode(guid: episodeId)?.show.feedURL
            ?? BrowsedEpisodes.shared.listened(guid: episodeId)?.feedURL
    }

    func ensureLoaded() async {
        await bootstrapTask?.value
    }

    // MARK: - Serialized row writes

    /// Consumed one-shot flag. ONLY a user-initiated path
    /// (last unsubscribe) may legitimately write an EMPTY store over a
    /// non-empty stock.
    private var userInitiatedEmptyWrite = false

    /// The row backend, opened once in the bootstrap. Nil when the database
    /// could not be opened: the stock then lives in memory for this run and
    /// the failure is in the log.
    /// The one opening of the rows: every caller awaits the same task, so a
    /// second caller never sees the flag before the store exists (measured
    /// in the simulator: the seed's save met a nil store and wrote nothing).
    private var rowsOpening: Task<PodcastRowStore?, Never>?

    private func openRows() async -> PodcastRowStore? {
        if let rowsOpening { return await rowsOpening.value }
        let opening = Task<PodcastRowStore?, Never> {
            do {
                return try await PodcastRowStore(connection: try MaerDatabase.shared.connection())
            } catch {
                Logger.rss.error("SUBROWS open failed reason=\(String(describing: error), privacy: .public)")
                return nil
            }
        }
        rowsOpening = opening
        return await opening.value
    }

    /// The stock as the rows hold it after the last handed-over write. The
    /// next write is the diff against this, never the whole stock.
    /// What the rows hold, as far as this run knows: the last LANDED write
    /// or the start read. Advances only when a write landed.
    private var rowBase: RowBase<[PodcastShow]> = .fresh
    /// The shows the rows are known to hold (the wipe guard's measure).
    private var landedShows: [PodcastShow] { rowBase.knownValue ?? [] }

    /// The one-time move of the document into the rows: one transaction,
    /// then the document is set aside as `.migrated` (kept, not deleted).
    /// A failure leaves the document where it is, so the next start tries
    /// again.
    @discardableResult
    nonisolated static func migrateDocument(at url: URL, stock: [PodcastShow], into rows: PodcastRowStore) async -> Bool {
        let started = Date()
        do {
            let counts = try await rows.replaceAll(stock)
            let ms = Int(Date().timeIntervalSince(started) * 1000)
            Logger.rss.notice("SUBROWS migrate: shows=\(counts.shows) episodes=\(counts.episodes) ms=\(ms)")
            try DocumentMigration.setAside(url)
            return true
        } catch {
            Logger.rss.error("SUBROWS migrate failed reason=\(String(describing: error), privacy: .public)")
            return false
        }
    }

    private func persist(_ snapshot: [PodcastShow]) {
        // Last line of defense. An EMPTY snapshot never overwrites
        // a non-empty stock unless the user explicitly emptied the list.
        // Refuse loudly + drop a tombstone note so the NEXT incident is
        // diagnosable instead of traceless (log-first).
        if snapshot.isEmpty, !userInitiatedEmptyWrite, !landedShows.isEmpty {
            Logger.rss.error("SUBSTORE wipe REFUSED: empty snapshot over \(self.landedShows.count) shows without user intent")
            let note = "wipe refused at \(Date()): empty snapshot, \(landedShows.count) shows, isLoaded=\(isLoaded)\n"
            let tombstone = fileURL.appendingPathExtension("wipe-refused.txt")
            try? note.data(using: .utf8)?.write(to: tombstone)
            return
        }
        userInitiatedEmptyWrite = false
        // Only the rows a change touched go to the database, in the order
        // the changes were made: each write waits for the one before it,
        // and the diff is taken against the stock of the write before, so a
        // later snapshot always lands last and complete.
        let previous = pendingWrite
        pendingWrite = Task { [weak self] in
            await previous?.value
            guard let self, let rows = await self.openRows() else { return }
            // The base is read HERE, after the write before landed or
            // failed. Known rows: the diff against them. Fresh rows: the
            // diff against nothing is the whole stock. Unknown rows: the
            // same diff, and it removes nothing, so rows nobody saw are
            // not buried.
            let base = self.rowBase
            let diff = PodcastRowDiff.compute(previous: base.knownValue ?? [], current: snapshot)
            guard !diff.isEmpty else { return }
            let started = Date()
            do {
                let counts = try await rows.apply(diff)
                let ms = Int(Date().timeIntervalSince(started) * 1000)
                Logger.rss.notice("SUBROWS save: shows=\(counts.shows)/-\(diff.showsRemoved.count) episodes=\(counts.episodes)/-\(diff.episodesRemoved.count) ms=\(ms) plan=\(String(describing: base.plan), privacy: .public)")
                self.rowBase = .known(snapshot)
            } catch {
                Logger.rss.error("SUBROWS save failed reason=\(String(describing: error), privacy: .public) base kept")
            }
        }
    }

    /// The last handed-over write (tests, teardown).
    private var pendingWrite: Task<Void, Never>?

    func awaitPendingWrites() async {
        await pendingWrite?.value
    }

    var hasSubscriptions: Bool { !shows.isEmpty }

    /// THE ONE playability check for episode item ids. Text-only
    /// rss: episodes (kept in the list, no enclosure) are never playable/
    /// queueable/downloadable; non-rss ids (abspod:, books, music) always are
    /// from this check's point of view.
    func isPlayableEpisode(itemId: String) -> Bool {
        guard itemId.hasPrefix("rss:") else { return true }
        guard let found = episode(guid: itemId) else { return true }
        return found.episode.isPlayable
    }

    #if DEBUG
    /// UI-test seeding only (see UITestSeed). Injects deterministic shows.
    func _seedForUITest(_ shows: [PodcastShow]) { self.shows = shows }
    /// Drive the wipe guard + load gate deterministically.
    func _testPersist(_ snapshot: [PodcastShow]) { persist(snapshot) }
    func _testSetLoaded(_ value: Bool) { isLoaded = value }
    func _testSave() { save() }
    var _testFileURL: URL { fileURL }
    /// What the rows hold, after `awaitPendingWrites`.
    func _testRowCounts() async -> PodcastRowStore.Counts? {
        guard let rows = await openRows() else { return nil }
        return try? await rows.counts()
    }
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
    /// Query parameters that carry feed IDENTITY. Two URLs differing in one of
    /// these are DIFFERENT feeds (private tokens, CMS show selectors) and must
    /// not collapse into one subscription. Everything else (tracking params
    /// etc.) is still stripped.
    /// Query parameters whose VALUES are access secrets. A feed carrying
    /// one is the token-URL premium class (access baked into the URL, no login).
    /// ONE source: the identity set below builds on this, no duplication.
    /// "freebie" joined after the ZEIT leak finding (their premium
    /// class uses `freebie=<token>`). ONE set feeds detection, masking AND
    /// the OPML-export guard.
    nonisolated static let secretQueryParams: Set<String> = PodcastFeedAddress.secretQueryParams

    nonisolated private static let identityQueryParams: Set<String> =
        secretQueryParams.union(["id", "show", "feed", "user", "podcast"])

    /// The show behind a statistics key. Episode ids are `rss:<feed key>:<guid>`
    /// and the statistics fold them to `rss:<feed key>`, while a show's own
    /// id is `feed:<feed key>`; the two never matched, so the statistics
    /// page showed keys instead of names.
    nonisolated static func showTitle(for showId: String, in shows: [PodcastShow]) -> String? {
        if let direct = shows.first(where: { $0.id == showId }) { return direct.title }
        let parts = showId.split(separator: ":", maxSplits: 1)
        guard parts.count == 2 else { return nil }
        let key = String(parts[1])
        return shows.first { $0.id == "feed:\(key)" || feedKey($0.feedURL) == key }?.title
    }

    /// Token-URL premium class; the rule itself lives in the core layer.
    nonisolated static func isTokenFeedURL(_ raw: String) -> Bool {
        PodcastFeedAddress.isTokenFeedURL(raw)
    }

    /// Provider-premium (Teil 5 cut): the comparable host of a feed URL.
    /// Scheme/`www.` stripped, lowercased, up to the first path segment.
    nonisolated static func feedHost(_ raw: String) -> String {
        var s = raw.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        s = s.replacingOccurrences(of: "https://", with: "")
             .replacingOccurrences(of: "http://", with: "")
        if s.hasPrefix("www.") { s.removeFirst(4) }
        if let slash = s.firstIndex(where: { $0 == "/" || $0 == "?" }) { s = String(s[..<slash]) }
        return s
    }

    /// Display/log-safe form. Secret parameter values become "••••",
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
    /// premium test has ONE home). The membership hosters whose
    /// personalised URLs carry the token in the PATH. Pure data.
    nonisolated private static let premiumHosts =
        ["patreon.com", "supercast", "supportingcast", "memberful", "acast.com/access",
         "supportingcast.fm", "supercast.com", "memberful.com", "steadyhq.com"]

    /// Feeds whose CHANNEL states `<itunes:block>`/`<podcast:block>`.
    /// The standard "do not list publicly" signal. Persisted per feed key,
    /// filled while parsing (no extra request), and read by the premium test.
    nonisolated static func blockedFeedKeys(defaults: UserDefaults = .standard) -> Set<String> {
        Set(defaults.stringArray(forKey: AppStorageKeys.blockedFeedKeys) ?? [])
    }

    nonisolated static func noteFeedBlocked(_ feedURL: String,
                                            defaults: UserDefaults = .standard) {
        var keys = blockedFeedKeys(defaults: defaults)
        guard keys.insert(feedKey(feedURL)).inserted else { return }
        defaults.set(Array(keys).sorted(), forKey: AppStorageKeys.blockedFeedKeys)
        Logger.rss.notice("PREMIUM feed-blocked signal: \(maskedFeedURL(feedURL), privacy: .public)")
        // A block signal is a statement about the FEED, not about
        // this device. It travels with the choice family.
        let key = feedKey(feedURL)
        Task { @MainActor in
            UserChoiceCloudSync.shared.noteFeedBlock(key)
        }
    }

    nonisolated static func isFeedBlocked(_ feedURL: String,
                                          defaults: UserDefaults = .standard) -> Bool {
        blockedFeedKeys(defaults: defaults).contains(feedKey(feedURL))
    }

    /// THE premium test: stored basic-auth credentials OR the token-URL class
    /// OR a known members-only host OR a MANUAL user marking (the escape
    /// hatch for unknown patterns; one truth feeds management, tab
    /// grouping, badges, the replace dialog AND the OPML-export guard).
    nonisolated static func isPremiumFeed(_ feedURL: String,
                                          defaults: UserDefaults = .standard) -> Bool {
        // A mirrored feed is NEVER premium. Its host login is
        // server infrastructure, not a paywall; its marking is the origin
        // capsule. First check, so no heuristic below can override it.
        if mirroredFeedKeys(defaults: defaults).contains(feedKey(feedURL)) { return false }
        if PodcastFeedAuth.hasCredentials(feedKey: feedKey(feedURL)) { return true }
        if isTokenFeedURL(feedURL) { return true }
        // The feed says it itself. Catches the path-token class
        // the query-param heuristic cannot see.
        if isFeedBlocked(feedURL) { return true }
        if manualPremiumFeedKeys().contains(feedKey(feedURL)) { return true }
        let lower = feedURL.lowercased()
        return premiumHosts.contains { lower.contains($0) }
    }

    /// The mirrored-group feed keys (maintained in rebuildCaches).
    nonisolated static func mirroredFeedKeys(defaults: UserDefaults = .standard) -> Set<String> {
        Set(defaults.stringArray(forKey: AppStorageKeys.pinchflatMirroredFeedKeys) ?? [])
    }

    /// Manual premium markings (persisted feed keys).
    nonisolated static func manualPremiumFeedKeys(defaults: UserDefaults = .standard) -> Set<String> {
        Set(defaults.stringArray(forKey: AppStorageKeys.premiumMarkedFeeds) ?? [])
    }

    nonisolated static func isManuallyMarkedPremium(_ feedURL: String,
                                                    defaults: UserDefaults = .standard) -> Bool {
        manualPremiumFeedKeys(defaults: defaults).contains(feedKey(feedURL))
    }

    nonisolated static func setManualPremium(_ marked: Bool, feedURL: String,
                                             defaults: UserDefaults = .standard) {
        var keys = manualPremiumFeedKeys(defaults: defaults)
        let key = feedKey(feedURL)
        if marked { keys.insert(key) } else { keys.remove(key) }
        defaults.set(Array(keys).sorted(), forKey: AppStorageKeys.premiumMarkedFeeds)
        // The statement travels. An un-marking as its own tombstone,
        // so the other device cannot resurrect it.
        Task { @MainActor in
            UserChoiceCloudSync.shared.notePremiumMark(key, marked: marked)
            shared.objectWillChange.send()
            // And the surfaces re-read. This used to be the CALLER's duty,
            // and all four remembered it, which is luck and not a promise: a
            // fifth would change the mark and leave every row showing the old
            // one, with nothing to say so. The obligation belongs to the
            // change, not to whoever makes it.
        }
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
    /// normalised feed URL). Idempotent. Later starts change nothing. When
    /// re-keying the guids the associated `localPosition` progress moves along
    /// (old→new) so the just-imported Apple progress is preserved.
    private func migrated(_ decoded: [PodcastShow]) -> [PodcastShow] {
        // The SAME re-keying rule as everywhere else. Including the
        // comparison the old private copy lacked.
        let (result, changed) = Self.migrate(decoded) { old, new in
            ListeningStore.move(from: old, to: new)
        }
        if changed {
            // Write back (serialized, off-main) so the cleanup is persistent.
            persist(result)
        }
        return result
    }

    /// Identity WITHOUT the secret VALUES. The ZEIT class rotates
    /// its `freebie` token, and since the token joined the identity params
    /// a rotated token spawned a TWIN of the same feed (the
    /// screenshot: two entries, identical masked URL). Same masked identity
    /// ⇒ same resource on one device.
    nonisolated static func collapseKey(_ feedURL: String) -> String {
        stableHash(maskedFeedURL(normalizeFeedURL(feedURL)))
    }

    /// Pure migration core (testable): re-key ids/guids, report every progress
    /// move via `moveProgress(old, new)`, dedupe shows of the same feed.
    /// Stage 1 on the exact identity, stage 2 on the MASKED
    /// identity so token rotations collapse too. The survivor of a stage-2
    /// collision is the entry with MORE episodes (the freshly parsed full
    /// feed carries the CURRENT token in its URL); the loser's episodes fold
    /// in re-keyed, progress rides along via `moveProgress`.
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

        // Stage 2: collapse token-rotation twins (same MASKED id).
        var byMasked: [String: String] = [:]   // collapseKey → surviving exact key
        var removedKeys = Set<String>()
        for key in order {
            guard let show = byKey[key] else { continue }
            let masked = collapseKey(show.feedURL)
            guard let survivorKey = byMasked[masked] else {
                byMasked[masked] = key
                continue
            }
            guard var survivor = byKey[survivorKey], let loser = byKey[key] else { continue }
            // The fuller entry survives (its URL carries the current token).
            if loser.episodes.count > survivor.episodes.count {
                var newSurvivor = loser
                collapseInto(&newSurvivor, from: survivor, moveProgress: moveProgress)
                byKey[key] = newSurvivor
                byKey[survivorKey] = nil
                byMasked[masked] = key
                removedKeys.insert(survivorKey)
            } else {
                collapseInto(&survivor, from: loser, moveProgress: moveProgress)
                byKey[survivorKey] = survivor
                byKey[key] = nil
                removedKeys.insert(key)
            }
            changed = true
        }
        if !removedKeys.isEmpty {
            order.removeAll { removedKeys.contains($0) }
        }

        return (order.compactMap { byKey[$0] }, changed)
    }

    /// Fold `loser` into `survivor`: episodes match by ORIGINAL guid, get
    /// re-keyed to the survivor's feed key (progress rides along), unmatched
    /// old episodes join the union. Logged loudly with MASKED urls.
    private nonisolated static func collapseInto(
        _ survivor: inout PodcastShow, from loser: PodcastShow,
        moveProgress: (String, String) -> Void
    ) {
        let survivorKey = feedKey(survivor.feedURL)
        var rekeyed = loser
        rekeyed.episodes = loser.episodes.map { ep in
            var e = ep
            let newGuid = "rss:\(survivorKey):\(originalGuid(ep.guid))"
            if newGuid != ep.guid {
                moveProgress(ep.guid, newGuid)
                e.guid = newGuid
            }
            return e
        }
        // Argument order on purpose: the SECOND side wins the feed facts,
        // and that has to be the survivor here, because its URL carries the
        // current token. The store facts survive from either side (see
        // merge), so the loser only loses its outdated address.
        survivor = merge(rekeyed, survivor)
        let loserMasked = maskedFeedURL(loser.feedURL)
        let survivorMasked = maskedFeedURL(survivor.feedURL)
        Logger.rss.notice("PREMIUM identity merge: \(loserMasked, privacy: .public) folded into \(survivorMasked, privacy: .public)")
    }

    /// Extract the original guid from `rss:<hash>:<original>` (which may itself
    /// contain colons → maxSplits 2).
    nonisolated static func originalGuid(_ guid: String) -> String {
        let parts = guid.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false)
        if parts.count == 3, parts[0] == "rss" { return String(parts[2]) }
        return guid
    }

    /// The same episode under another feed key: an id with the same
    /// original guid among the followed episodes, never the id itself.
    /// The guid is the episode's own name in its feed, so two feed keys
    /// for one show (a moved host, a premium twin) meet here.
    nonisolated static func twinEpisodeId(for id: String, among guids: [String]) -> String? {
        let wanted = originalGuid(id)
        guard wanted != id, !wanted.isEmpty else { return nil }
        return guids.first { $0 != id && originalGuid($0) == wanted }
    }

    /// Merge two versions of the same show: episodes as a union over `guid`,
    /// newest first. `internal` so the RSS hardening (never shrink on a thin
    /// fetch) can be driven from a unit test.
    ///
    /// **Classify fields instead of picking a side.**
    ///
    /// Picking the side with more episodes and then patching individual fields
    /// back requires someone to remember every field, every time. Two fields
    /// died that way before.
    ///
    /// The classification is objective, not a judgement call:
    ///  * **Feed facts** (title, image, description, categories, the
    ///    announced duration): a fresh parse knows them best, so the fresh
    ///    side wins.
    ///  * **Store facts** (`origin`, the measured asset length): a fresh
    ///    parse CANNOT know them at all. They survive from the stored side,
    ///    no matter which side has more episodes.
    ///
    /// The episode list stays a union over `guid`: a thin parse (valid title,
    /// few episodes) must never empty the cache. On a duplicate `guid` the
    /// classification applies at EPISODE level too, otherwise the same fact
    /// dies, only less visibly.
    ///
    /// The store facts are not taken blindly from `stored`. Whoever has them
    /// keeps them (`stored ?? fresh`). On a refresh that is the same thing,
    /// because a fresh parse never has them. But `collapseInto` uses this
    /// same merge to fold a twin entry into the survivor, and there the
    /// loser's origin must not be lost just because it is the second
    /// argument.
    nonisolated static func merge(_ stored: PodcastShow, _ fresh: PodcastShow) -> PodcastShow {
        var result = fresh
        result.origin = stored.origin ?? fresh.origin

        var storedByGuid: [String: PodcastEpisode] = [:]
        for episode in stored.episodes { storedByGuid[episode.guid] = episode }

        var seen = Set<String>()
        var episodes: [PodcastEpisode] = []
        for var episode in fresh.episodes where seen.insert(episode.guid).inserted {
            if let known = storedByGuid[episode.guid] { carryStoreFacts(from: known, into: &episode) }
            episodes.append(episode)
        }
        for episode in stored.episodes where seen.insert(episode.guid).inserted {
            episodes.append(episode)
        }
        result.episodes = episodes.sorted { $0.pubDate > $1.pubDate }
        return result
    }

    /// What only the store knows about an EPISODE. When this list grows, the
    /// fence `storeFactsSurviveARefresh` has to grow with it. That is exactly
    /// what it is for.
    private nonisolated static func carryStoreFacts(from stored: PodcastEpisode,
                                                    into fresh: inout PodcastEpisode) {
        // Only when the other side carries no measurement of its own,
        // otherwise an older value would beat a newer one.
        if fresh.measuredDuration == nil, let measured = stored.measuredDuration, measured > 0 {
            fresh.measuredDuration = measured
            // Mirrored so every reader sees the best known length.
            fresh.duration = measured
        }
    }

    // MARK: - Subscriptions

    /// Subscribe to a feed (loads + parses immediately). Already-present feeds
    /// are only refreshed.
    /// `notesCloud`: a person subscribing (or importing) is a choice that
    /// travels; a server pull or a mirror is mechanics and never notes.
    /// `adopting`: the fetch serves the account's list, not the person's
    /// own request. A sign-in demand then marks the feed as needing one
    /// instead of failing silently and being retried on every reconcile.
    /// `isSingleUserAct`: did the person subscribe to THIS feed, one at a
    /// time? False for every mechanic AND for the bulk import, which reports
    /// its own summary. It is a fact of its own and not `notesCloud` in
    /// disguise: an imported subscription must still travel to the cloud.
    func subscribe(urlString: String, notesCloud: Bool = true, adopting: Bool = false,
                   isSingleUserAct: Bool = true,
                   statementT: Double? = nil) async -> Bool {
        await ensureLoaded()   // No mutation before the disk load
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = normalizedFeedURL(trimmed) else { return false }
        let outcome: FeedFetchOutcome
        if let fetcher = _testFeedFetcher {
            outcome = await fetcher(url)
        } else {
            outcome = await Self.fetchOutcome(feedURL: url)
        }
        guard case .show(let show) = outcome else {
            // Every failed adoption gets a visible reason, not a silent
            // retry on the next reconcile.
            if adopting {
                switch outcome {
                case .status(let status):
                    markNotFollowed(feedURL: url.absoluteString,
                                    reason: .init(StatusMeaning.from(status: status)), status: status,
                                    statementT: statementT)
                case .failed(let reason):
                    markNotFollowed(feedURL: url.absoluteString, reason: reason, statementT: statementT)
                case .show:
                    break
                }
            }
            return false
        }
        // The OTHER direction of the premium offer below: the ARRIVING feed is
        // the free twin of a show already subscribed as premium (the Apple
        // import walks Apple's list, which still carries the free feed). The
        // exact-address check cannot see that, so the import subscribed the
        // free ZEIT copy next to the paid one. Skipped here. And any stored
        // progress under the skipped feed's guids is redirected onto the
        // premium episodes first (target-empty guard, the replacement path's
        // rule), so nothing the twin knew is lost.
        if shows.first(where: { $0.id == show.id }) == nil,
           !Self.isPremiumFeed(show.feedURL),
           let premium = shows.first(where: {
               Self.isPremiumFeed($0.feedURL)
                   && PodcastPremiumMatch.sameShow(titleA: $0.title, titleB: show.title)
           }) {
            let matches = PodcastPremiumMatch.episodeMatches(free: show.episodes,
                                                             premium: premium.episodes)
            // The FRESH case needs a bridge, not only the redirect below:
            // Apple's progress rows arrive AFTER this skip and carry the free
            // feed's enclosures. Without the bridge only the title fallback
            // caught some of them, the rest fell silently.
            twinEnclosureBridge.merge(
                PodcastPremiumMatch.enclosureBridge(free: show.episodes,
                                                    premium: premium.episodes)) { old, _ in old }
            var redirected = 0
            for (freeGuid, premiumGuid) in matches {
                guard let stored = ListeningStore.backup(freeGuid),
                      !ListeningStore.hasStand(premiumGuid) else { continue }
                ListeningStore.store(premiumGuid, entry: stored)
                redirected += 1
            }
            lastFreeTwinSkip = (show.title, redirected)
            Logger.rss.notice("SUBSCRIBE skipped free twin of premium \(show.title, privacy: .public): progress redirected=\(redirected)")
            if redirected > 0 { PodcastProgressStore.shared.reload() }
            return true
        }
        if let idx = shows.firstIndex(where: { $0.id == show.id }) {
            // Re-subscribe must not blindly replace: a weak parse (valid title,
            // few/zero episodes) would drop the cached episodes. Union instead.
            shows[idx] = Self.merge(shows[idx], show)
        } else {
            shows.insert(show, at: 0)
            if PodcastSubscribeNotice.shouldTell(episodeCount: show.episodes.count,
                                                 isSingleUserAct: isSingleUserAct,
                                                 isFirstSubscribe: true) {
                emptyFeedNotice = show.title
            }
            // A NEW premium feed of ANY class (credentials, token URL,
            // members host, manual mark) that looks like an existing free
            // subscription → offer the replacement.
            // Conservative same-show test; the user decides.
            if Self.isPremiumFeed(show.feedURL),
               let free = shows.first(where: {
                   $0.id != show.id
                       && !Self.isPremiumFeed($0.feedURL)
                       && PodcastPremiumMatch.sameShow(titleA: $0.title, titleB: show.title)
               }) {
                pendingPremiumReplacement = PremiumReplacementOffer(
                    freeShowId: free.id, premiumShowId: show.id, showTitle: show.title)
            }
        }
        save()
        if notesCloud {
            UserChoiceCloudSync.shared.noteSubscription(feedURL: show.feedURL, subscribed: true)
        }
        return true
    }

    /// Move the matched episodes' local progress free→premium
    /// (the migrateLocalPosition pattern: target-empty guard), adopt their
    /// downloads, then unsubscribe the free show. Unmatched free episodes keep
    /// nothing to lose. Their progress keys simply become orphaned history.
    @discardableResult
    func replaceFreeWithPremium(_ offer: PremiumReplacementOffer) -> (progressMoved: Int, downloadsAdopted: Int) {
        defer { pendingPremiumReplacement = nil }
        guard let free = shows.first(where: { $0.id == offer.freeShowId }),
              let premium = shows.first(where: { $0.id == offer.premiumShowId }) else { return (0, 0) }
        let matches = PodcastPremiumMatch.episodeMatches(free: free.episodes, premium: premium.episodes)
        var moved = 0
        var adopted = 0
        for (freeGuid, premiumGuid) in matches {
            if ListeningStore.hasStand(freeGuid) {
                // ONE re-keying, one rule. This used to be a second
                // implementation beside the stock's: it SKIPPED any occupied
                // target, so an OLDER stand there was never healed. The same
                // defect as the unconditional overwrite, turned the other way.
                ListeningStore.move(from: freeGuid, to: premiumGuid)
                moved += 1
            }
            if DownloadManager.shared.adoptDownload(from: freeGuid, to: premiumGuid) {
                adopted += 1
            }
        }
        unsubscribe(id: free.id)
        PodcastProgressStore.shared.reload()
        // The takeover is visible in the log (titles only, no URLs.
        // Premium URLs can carry secrets).
        Logger.rss.notice("premium replacement: \(offer.showTitle, privacy: .public) — \(matches.count) matched, \(moved) progress moved, \(adopted) downloads adopted")
        return (moved, adopted)
    }

    /// Tag a mirrored feed's provenance.
    func setOrigin(_ origin: String?, forFeedURL feedURL: String) {
        guard let index = shows.firstIndex(where: { $0.feedURL == feedURL }) else { return }
        shows[index].origin = origin
        save()
    }

    /// Every episode guid of the mirrored group. Hosts resolve
    /// membership ONCE per render and hand rows a Bool (cell-cost rule:
    /// no per-row shows×episodes scan).
    func mirroredEpisodeGuids() -> Set<String> {
        Set(shows.filter { $0.origin != nil }.flatMap { $0.episodes.map(\.guid) })
    }

    /// Does this feed belong to a mirrored group? Carried by the
    /// `origin` field only. Never a URL heuristic. Drives the
    /// "YouTube" origin capsule on surfaces OUTSIDE the group row.
    func isMirrored(feedURL: String) -> Bool {
        let normalized = Self.normalizeFeedURL(feedURL)
        return shows.contains {
            $0.origin != nil && Self.normalizeFeedURL($0.feedURL) == normalized
        }
    }

    /// A SERVER-driven remove (channel left the mirror).
    /// Deliberately NOT the user-unsubscribe: it must not join the gpodder
    /// user-intent set. The mirrored group is no subscription set of the
    /// user's, and progress stays like any unsubscribe.
    func removeMirrored(feedURL: String) {
        shows.removeAll { $0.feedURL == feedURL }
        save()
    }

    /// `notesCloud: false` for removals a MECHANISM performs (a gpodder
    /// server drop): the account's family carries the person's decisions
    /// only, and a tombstone written by mechanics would bury the feed on
    /// every device of the account.
    func unsubscribe(id: String, notesCloud: Bool = true) {
        // A user unsubscribe may legitimately empty the
        // store; the normalized URL joins the user-intent set so the gpodder
        // sync may propagate THIS single remove immediately (derived removes
        // wait for the two-sync confirmation instead).
        var removedFeedURL: String?
        if let show = shows.first(where: { $0.id == id }) {
            Self.recordUserRemovedFeed(Self.normalizeFeedURL(show.feedURL))
            removedFeedURL = show.feedURL
        }
        shows.removeAll { $0.id == id }
        if shows.isEmpty { userInitiatedEmptyWrite = true }
        save()
        // The person's unsubscribe travels as a tombstone.
        if notesCloud, let removedFeedURL {
            UserChoiceCloudSync.shared.noteSubscription(feedURL: removedFeedURL, subscribed: false)
        }
    }

    /// Subscriptions adopted from the account (a device without a podcast
    /// server follows the account's list): leave what the others left,
    /// follow what they follow. Following fetches the feeds one by one in
    /// the background, throttled like a refresh; no automatic download and
    /// no "new episode" notification for what merely arrives. The states
    /// already in the pot then apply to the episodes.
    func adoptCloudSubscriptions(added: [(feedURL: String, t: Double)], removed: [String]) {
        Task { [weak self] in
            guard let self else { return }
            await self.ensureLoaded()
            var removedTitles: [String] = []
            for feedKey in removed {
                if let show = self.shows.first(where: { Self.feedKey($0.feedURL) == feedKey }),
                   show.origin == nil {
                    // The family carries the person's decisions only, so a
                    // tombstone is the person's unsubscribe made elsewhere:
                    // it joins the user-intent set, and the next gpodder
                    // round pushes THIS single remove at once instead of
                    // holding it as a derived one. Stands stay, here and on
                    // the server: an unsubscribe removes the feed, never
                    // what was heard.
                    Self.recordUserRemovedFeed(Self.normalizeFeedURL(show.feedURL))
                    self.shows.removeAll { $0.id == show.id }
                    self.save()
                    removedTitles.append(show.title)
                    Logger.rss.notice("SUBSCRIBE cloud tombstone applied: \(feedKey, privacy: .private(mask: .hash))")
                }
            }
            let pendingBefore = Set(self.feedsNotFollowed.keys)
            var followed = 0
            for entry in added.sorted(by: { $0.t < $1.t }) {
                let key = Self.feedKey(entry.feedURL)
                guard !self.shows.contains(where: { Self.feedKey($0.feedURL) == key }) else { continue }
                // The account offers an unfollowed feed on EVERY reconcile
                // (the statement stays open until this device holds it), so
                // a run that is still fetching must not fetch it twice.
                guard !self.adoptingFeedKeys.contains(key) else { continue }
                // A feed that failed or was dismissed here is not fetched
                // again until the person retries, signs in, or the account
                // brings a newer statement (no endless retry).
                guard FeedAdoptionPending.shouldAttempt(feedKey: key, statementT: entry.t) else {
                    Logger.rss.notice("SUBSCRIBE cloud adoption skipped, not followed: \(key, privacy: .private(mask: .hash))")
                    continue
                }
                self.adoptingFeedKeys.insert(key)
                let ok = await self.subscribe(urlString: entry.feedURL, notesCloud: false, adopting: true,
                                              isSingleUserAct: false, statementT: entry.t)
                self.adoptingFeedKeys.remove(key)
                if ok { followed += 1 }
                Logger.rss.notice("SUBSCRIBE cloud adopted: \(key, privacy: .private(mask: .hash)) ok=\(ok)")
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
            // The history says what iCloud DID here: feeds followed, feeds
            // removed by name (a removal is a possible loss and must be
            // inspectable), feeds waiting for a login. Nothing for a run
            // that changed nothing. The history is the app's; a test
            // instance must not write the host's file.
            let newlyPending = Set(self.feedsNotFollowed.keys).subtracting(pendingBefore)
            let needSignIn = newlyPending.filter { self.feedsNotFollowed[$0]?.reason == .signIn }.count
            let otherFailures = newlyPending.count - needSignIn
            if followed + removedTitles.count + newlyPending.count > 0, self === Self.shared {
                SyncHistoryStore.shared.append(SyncHistory.entry(
                    service: .iCloud, direction: .down,
                    counters: [.init(key: .subscriptionsDown, value: followed),
                               .init(key: .subscriptionsRemovedLocally, value: removedTitles.count),
                               .init(key: .subscriptionsNeedingSignIn, value: needSignIn),
                               .init(key: .subscriptionsNotFollowed, value: otherFailures)],
                    duration: 0, removedFeeds: removedTitles,
                    deviceId: SyncHistoryStore.deviceId))
            }
        }
    }

    /// Feed keys an adoption run is fetching right now.
    private var adoptingFeedKeys: Set<String> = []

    // MARK: - Feeds not followed yet (adoption failed, with its reason)

    private func markNotFollowed(feedURL: String, reason: FeedAdoptionPending.Reason, status: Int? = nil,
                                 statementT: Double? = nil) {
        let key = Self.feedKey(feedURL)
        FeedAdoptionPending.mark(feedKey: key, feedURL: feedURL, reason: reason, status: status,
                                 statementT: statementT)
        feedsNotFollowed = FeedAdoptionPending.pending()
        Logger.rss.notice("SUBSCRIBE cloud adoption failed: \(key, privacy: .private(mask: .hash)) reason=\(reason.rawValue, privacy: .public) status=\(status ?? 0)")
    }

    /// A retry (the button, or a saved login) reopens the way: one fresh
    /// attempt, in the background. A second failure marks the feed again.
    /// No-op for unmarked feeds, so the login form may call this for every
    /// save.
    func retryAdoption(feedKey: String) {
        guard let entry = feedsNotFollowed[feedKey] else { return }
        FeedAdoptionPending.clear(feedKey: feedKey)
        feedsNotFollowed = FeedAdoptionPending.pending()
        Task { [weak self] in
            guard let self else { return }
            let ok = await self.subscribe(urlString: entry.feedURL, notesCloud: false, adopting: true, isSingleUserAct: false)
            Logger.rss.notice("SUBSCRIBE cloud adoption retried: \(feedKey, privacy: .private(mask: .hash)) ok=\(ok)")
        }
    }

    /// The person dismisses the placeholder: a LOCAL choice. The account
    /// keeps the subscription (unsubscribing lives at the show, on a device
    /// that holds it); this device stops offering the feed until the
    /// account brings a newer statement than the one dismissed.
    func removeNotFollowed(feedKey: String) {
        guard let entry = feedsNotFollowed[feedKey] else { return }
        FeedAdoptionPending.mark(feedKey: feedKey, feedURL: entry.feedURL, reason: .dismissed,
                                 statementT: entry.statementT)
        feedsNotFollowed = FeedAdoptionPending.pending()
        Logger.rss.notice("SUBSCRIBE cloud adoption dismissed here: \(feedKey, privacy: .private(mask: .hash))")
    }

    /// A placeholder show for the surfaces that take a `PodcastShow` (the
    /// login form): host as title, no episodes, nothing persisted.
    nonisolated static func placeholderShow(feedKey: String, feedURL: String) -> PodcastShow {
        let host = feedHost(feedURL)
        return PodcastShow(id: feedKey, title: host.isEmpty ? feedURL : host, author: nil,
                    artworkURL: nil, description: nil, feedURL: feedURL, episodes: [])
    }

    /// The family's view of the local list: feed key ⇒ address, mirrors
    /// excluded (a mirror is the server's list, not a choice); nil until
    /// the store has loaded, so nothing reads an unloaded store as empty.
    func subscriptionsForCloud() -> [String: String]? {
        guard isLoaded else { return nil }
        var out: [String: String] = [:]
        for show in shows where show.origin == nil {
            out[Self.feedKey(show.feedURL)] = show.feedURL
        }
        return out
    }

    /// Normalized URLs the USER unsubscribed. The only removes the
    /// gpodder sync may push to the server without the two-sync confirmation.
    nonisolated static func userRemovedFeeds(defaults: UserDefaults = .standard) -> Set<String> {
        Set(defaults.stringArray(forKey: AppStorageKeys.gpodderUserRemovedFeeds) ?? [])
    }

    nonisolated static func recordUserRemovedFeed(_ norm: String, defaults: UserDefaults = .standard) {
        var set = userRemovedFeeds(defaults: defaults)
        set.insert(norm)
        defaults.set(Array(set).sorted(), forKey: AppStorageKeys.gpodderUserRemovedFeeds)
    }

    nonisolated static func consumeUserRemovedFeeds(_ applied: Set<String>, defaults: UserDefaults = .standard) {
        let rest = userRemovedFeeds(defaults: defaults).subtracting(applied)
        defaults.set(Array(rest).sorted(), forKey: AppStorageKeys.gpodderUserRemovedFeeds)
    }

    /// Load a show's full history via PodcastIndex (if a key is set) and merge
    /// it into the persisted episodes. Same `rss:<feedKey>:<guid>` ids as the
    /// feed → dedup + shared progress key. Returns: number of NEW episodes added.
    func loadFullHistory(showId: String) async -> Int {
        await ensureLoaded()
        guard AppStorageKeys.podcastIndexActive,
              let idx = shows.firstIndex(where: { $0.id == showId }) else { return 0 }
        let show = shows[idx]
        let dir = PodcastIndexDirectory(
            key: AppStorageKeys.podcastIndexEffectiveKey,
            secret: AppStorageKeys.podcastIndexEffectiveSecret
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
        /// Free twins of an already-subscribed premium feed. Skipped, their
        /// stored progress redirected onto the premium episodes.
        var freeTwinsSkipped = 0
        /// Shows the import named that this device already followed.
        var alreadySubscribed = 0
        /// Feeds that parsed into a valid show but brought no episode. They
        /// ARE subscribed. Counted here instead of raising an alert per feed:
        /// a run over hundreds would have shown the last empty one by name
        /// and hidden the rest.
        var emptyFeeds = 0
        /// Titles of the shows that are new through this import.
        var subscribedTitles: [String] = []
        /// Of `progressApplied`, the states that mark an episode finished.
        var finishedApplied = 0
        /// States that met a newer or finished local entry and stayed out.
        var keptLocal = 0
        /// Of `keptLocal`: states this device already knew (finished here,
        /// known from iCloud or an earlier import, or newer here).
        var keptKnown = 0
        /// Of `keptLocal`: states with nothing to take over (under a second
        /// played, not finished). On a fresh device this is the whole count.
        var nothingToAdopt = 0
        /// Titles of the states no episode claimed. Named, not only
        /// counted, so a half success is visible.
        var unmatched: [String] = []
        /// The same states, grouped by the show the SOURCE named, with the
        /// ladder's reasons: the surface reports itself.
        var unmatchedGroups: [UnmatchedGroup] = []
        /// States the ladder placed only because the source was asked for
        /// the episode by itself, grouped by show. Pocket Casts only.
        var lookupGroups: [LookupGroup] = []
        var lookupAsked = 0
        var lookupAnswered = 0
    }

    struct LookupGroup: Identifiable {
        var show: String
        var id: String { show }
        var count = 0
    }

    struct UnmatchedGroup: Identifiable {
        /// The show as the source calls it, else the feed's host.
        var show: String
        var id: String { show }
        var count = 0
        var reasons: [ForeignStateMatcher.UnmatchedReason: Int] = [:]
        /// What the feed carries here: episode count and oldest date (ms).
        var feedEpisodes = 0
        var oldestInFeed: Double?
        var titles: [String] = []
    }

    /// Set by `subscribe` when it skips a free twin (title, redirected count).
    /// Read by the import loops for their counter, never shown raw.
    private(set) var lastFreeTwinSkip: (title: String, redirected: Int)?

    /// Normalized free enclosure → premium guid, collected while an import
    /// skips free twins. The matcher reads it as its twin rung. Cleared at
    /// the start of each import.
    private var twinEnclosureBridge: [String: String] = [:]

    /// Every episode this device holds a state for, in the seam the export
    /// writes and the import reads back. A finished episode without a
    /// duration carries the sentinel; it goes out as finished with no
    /// position, which is what the reader turns back into the sentinel.
    func exportableStates() -> [ForeignListeningState] {
        var states: [ForeignListeningState] = []
        for show in shows {
            for episode in show.episodes {
                guard let entry = ListeningStore.backup(episode.guid),
                      let state = OPMLExport.exportedState(
                        entry: entry, feedURL: show.feedURL,
                        guid: ForeignStateMatcher.rawGUID(storedGUID: episode.guid),
                        enclosureURL: episode.audioURL, link: episode.link, title: episode.title,
                        duration: episode.duration,
                        archived: ForeignMarks.isArchived(episode.guid)) else { continue }
                states.append(state)
            }
        }
        return states
    }

    /// The one import for every foreign source: subscribe to each feed,
    /// then hand the states to the one adopter. The caller has already
    /// read and previewed the library.
    func importForeignLibrary(_ library: ForeignLibrary) async -> ImportResult {
        var result = ImportResult()
        twinEnclosureBridge = [:]
        for feed in library.feedURLs {
            lastFreeTwinSkip = nil
            // A show already followed is refreshed, not imported: the
            // summary must not count it as new.
            let key = Self.feedKey(feed)
            let known = shows.contains { Self.feedKey($0.feedURL) == key }
            // A bulk run is the person acting, but not on THIS feed. The
            // empty ones are counted below and reported in this summary.
            if await subscribe(urlString: feed, isSingleUserAct: false) {
                if shows.first(where: { Self.feedKey($0.feedURL) == key })?.episodes.isEmpty == true {
                    result.emptyFeeds += 1
                }
                if lastFreeTwinSkip != nil {
                    result.freeTwinsSkipped += 1
                } else if known {
                    result.alreadySubscribed += 1
                } else {
                    result.subscribed += 1
                    if let title = shows.first(where: { Self.feedKey($0.feedURL) == Self.feedKey(feed) })?.title {
                        result.subscribedTitles.append(title)
                    }
                }
            } else { result.failed += 1 }
        }
        result.paidSkipped = library.unimportablePaidCount
        guard !library.states.isEmpty else { return result }
        let outcome = applyForeignStates(library.states)
        result.progressApplied = outcome.applied
        result.finishedApplied = outcome.finished
        result.keptLocal = outcome.keptLocal
        result.nothingToAdopt = outcome.nothingToAdopt
        result.keptKnown = outcome.keptLocal - outcome.nothingToAdopt
        result.unmatched = outcome.unmatched
        result.unmatchedGroups = outcome.unmatchedGroups
        result.lookupGroups = outcome.lookupGroups
        result.lookupAsked = library.lookupAsked
        result.lookupAnswered = library.lookupAnswered
        if library.lookupAsked > 0 {
            let matched = outcome.lookupGroups.reduce(0) { $0 + $1.count }
            Logger.rss.notice("FOREIGN lookup total asked=\(library.lookupAsked) answered=\(library.lookupAnswered) matched=\(matched)")
        }
        // Listen log: the import wrote positions past the played threshold.
        // Re-scan the (now-subscribed) shows with full metadata. A
        // targeted rescan, not the one-time backfill flag.
        PodcastListenLog.shared.rescan(shows: shows)
        // The imported states are local truth now; iCloud learns of them
        // here, not at the next launch. Measured on two devices: without
        // this the second device saw nothing until the first was restarted.
        PodcastCloudSync.shared.reconcile()
        return result
    }

    /// Maps foreign states onto our episodes through the ladder and writes
    /// what the conflict rule admits into `localPosition`, the store the
    /// player uses. The plan carries one state per episode; duplicates in
    /// the source were reduced before the rule, so the file order cannot
    /// change where an episode ends.
    private func applyForeignStates(_ states: [ForeignListeningState])
        -> (applied: Int, finished: Int, keptLocal: Int, nothingToAdopt: Int,
            unmatched: [String], unmatchedGroups: [UnmatchedGroup], lookupGroups: [LookupGroup]) {
        var targets: [ForeignMatchTarget] = []
        for show in shows {
            let feedKey = Self.feedKey(show.feedURL)
            for episode in show.episodes {
                targets.append(ForeignMatchTarget(
                    id: episode.guid,
                    rawGUID: ForeignStateMatcher.rawGUID(storedGUID: episode.guid),
                    enclosureURL: episode.audioURL,
                    link: episode.link,
                    title: episode.title,
                    feedKey: feedKey))
            }
        }
        let plan = ForeignStateMatcher.plan(states: states, targets: targets,
                                            twinBridge: twinEnclosureBridge,
                                            feedKeyOf: Self.feedKey)
        var updated = shows
        var applied = 0
        var finished = 0
        var keptLocal = 0
        var steps: [ForeignStateMatcher.Step: Int] = [:]
        var reasons: [ForeignStateMerge.Reason: Int] = [:]
        var keeps: [ForeignStateMerge.Keep: Int] = [:]
        for match in plan.matches {
            guard let idx = episodeIndex[match.targetID] else { continue }
            steps[match.step, default: 0] += 1
            // A feed without a duration takes the source's, otherwise a
            // finished mark could never be read back as finished.
            if updated[idx.show].episodes[idx.episode].duration <= 0,
               let known = match.state.duration, known > 0 {
                updated[idx.show].episodes[idx.episode].duration = known
            }
            let duration = updated[idx.show].episodes[idx.episode].duration
            let local = ListeningStore.backup(match.targetID)
            let adoption: (entry: [Double], reason: ForeignStateMerge.Reason)
            switch ForeignStateMerge.verdict(local: local, foreign: match.state, duration: duration) {
            case .keep(let why):
                keptLocal += 1
                keeps[why, default: 0] += 1
                continue
            case .adopt(let entry, let reason):
                adoption = (entry, reason)
            }
            ListeningStore.store(match.targetID, entry: adoption.entry)
            // The marks: imported keeps it out of the listening time until
            // it is heard here; archived travels back out with an export.
            ForeignMarks.markImported(match.targetID)
            if match.state.archived { ForeignMarks.markArchived(match.targetID) }
            applied += 1
            if match.state.finished { finished += 1 }
            reasons[adoption.reason, default: 0] += 1
            #if DEBUG
            // One line per adoption, so a run that adopts where it should
            // not shows the two entries it decided between.
            Logger.rss.debug("FOREIGN adopt \(match.targetID, privacy: .public) reason=\(adoption.reason.rawValue, privacy: .public) local=\(String(describing: local), privacy: .public) foreign=\(match.state.position)/\(match.state.finished)/\(String(describing: match.state.stampedAt), privacy: .public)")
            #endif
        }
        // What the asking gained: the placed states whose handle came from
        // asking the source for the episode, by show, in match order.
        var lookupCounts: [String: Int] = [:]
        var lookupOrder: [String] = []
        for match in plan.matches where match.state.handleFromLookup {
            let name = match.state.showTitle ?? match.state.feedURL.map(Self.feedHost) ?? "?"
            if lookupCounts[name] == nil { lookupOrder.append(name) }
            lookupCounts[name, default: 0] += 1
        }
        let lookupGroups = lookupOrder.map { LookupGroup(show: $0, count: lookupCounts[$0] ?? 0) }
        let unmatched = plan.unmatched.map { $0.episodeTitle ?? $0.enclosureURL ?? $0.episodeLink ?? "?" }
        // The unmatched, grouped by the show the source named, with the
        // ladder's reasons and what the feed carries here. One log line
        // per show, so a preview screenshot and the log tell the same.
        var groups: [String: UnmatchedGroup] = [:]
        var groupOrder: [String] = []
        for (state, why) in zip(plan.unmatched, plan.whyUnmatched) {
            let name = state.showTitle ?? state.feedURL.map(Self.feedHost) ?? "?"
            if groups[name] == nil {
                var group = UnmatchedGroup(show: name)
                if let feedURL = state.feedURL,
                   let show = shows.first(where: { Self.feedKey($0.feedURL) == Self.feedKey(feedURL) }) {
                    group.feedEpisodes = show.episodes.count
                    group.oldestInFeed = show.episodes.map(\.pubDate).filter { $0 > 0 }.min()
                }
                groups[name] = group
                groupOrder.append(name)
            }
            groups[name]?.count += 1
            groups[name]?.reasons[why, default: 0] += 1
            if let title = state.episodeTitle, (groups[name]?.titles.count ?? 0) < 40 {
                groups[name]?.titles.append(title)
            }
        }
        let unmatchedGroups = groupOrder.compactMap { groups[$0] }
        for group in unmatchedGroups {
            let reasonLine = ForeignStateMatcher.UnmatchedReason.allCases
                .map { "\($0.rawValue)=\(group.reasons[$0] ?? 0)" }.joined(separator: " ")
            let oldest = group.oldestInFeed.map { Date(timeIntervalSince1970: $0 / 1000).formatted(.iso8601.year().month().day()) } ?? "none"
            Logger.rss.notice("FOREIGN unmatched show=\(Self.stableHash(group.show), privacy: .public) states=\(group.count) feedEpisodes=\(group.feedEpisodes) oldestInFeed=\(oldest, privacy: .public) \(reasonLine, privacy: .public) title=\(group.show, privacy: .private)")
        }
        let rungs = ForeignStateMatcher.Step.allCases.map { "\($0.rawValue)=\(steps[$0] ?? 0)" }.joined(separator: " ")
        let why = ForeignStateMerge.Reason.allCases.map { "\($0.rawValue)=\(reasons[$0] ?? 0)" }.joined(separator: " ")
        // The kept states by reason: "knew better" is only three of the
        // four, and on a fresh device those three must read zero.
        let keptWhy = ForeignStateMerge.Keep.allCases.map { "\($0.rawValue)=\(keeps[$0] ?? 0)" }.joined(separator: " ")
        Logger.rss.notice("FOREIGN import: applied=\(applied) finished=\(finished) \(rungs, privacy: .public) \(why, privacy: .public) localKept=\(keptLocal) \(keptWhy, privacy: .public) unmatched=\(unmatched.count)")
        if applied > 0 {
            shows = updated
            save()
            PodcastProgressStore.shared.reload()
        }
        return (applied, finished, keptLocal, keeps[.nothingToAdopt] ?? 0, unmatched, unmatchedGroups, lookupGroups)
    }

    /// Make enclosure URLs comparable: drop query & scheme, lowercase, trim /.
    nonisolated static func normalizeEnclosure(_ raw: String) -> String {
        ForeignStateMatcher.normalizeEnclosure(raw)
    }

    /// Adopt the real asset duration measured by the player. Feeds often omit
    /// or round `itunes:duration`, and without a duration the played/remaining
    /// state cannot be derived. Persisted so lists and play-state math work
    /// from then on.
    /// The latest known length of an episode. After playback the one MEASURED
    /// from the asset, otherwise the one the feed claims. The two diverge when
    /// ad slots are announced but left empty, so whoever writes "played" takes
    /// the same number as whoever reads it later.
    func episodeDuration(guid: String) -> Double? {
        guard let idx = episodeIndex[guid] else { return nil }
        let value = shows[idx.show].episodes[idx.episode].duration
        return value > 0 ? value : nil
    }

    func updateEpisodeDuration(guid: String, duration: Double) {
        guard duration > 0, duration.isFinite, let idx = episodeIndex[guid] else { return }
        guard abs(shows[idx.show].episodes[idx.episode].duration - duration) > 1
                || shows[idx.show].episodes[idx.episode].measuredDuration == nil else { return }
        // Into BOTH fields: `duration` stays the best known length for every
        // reader, `measuredDuration` is the store fact the merge carries
        // across the next refresh.
        shows[idx.show].episodes[idx.episode].duration = duration
        shows[idx.show].episodes[idx.episode].measuredDuration = duration
        save()
    }

    /// Reload all feeds (pull-to-refresh). Failed ones keep their cached state.
    func refreshAll() async {
        // NEVER mutate before the disk load. The BGAppRefresh
        // cold start hit exactly this window and wiped the store.
        await ensureLoaded()
        // TF bib-toggles: RSS source off (podcast tab ∧ RSS toggle) → no feed
        // fetches from any caller (background refresh, tab load, pull-to-refresh).
        // THE one gate for the bulk RSS refresh; deliberate user actions
        // (subscribe/preview) stay ungated.
        guard AppStorageKeys.rssActive else { return }
        var updated = shows
        for (index, show) in shows.enumerated() {
            if let url = PodcastFeedAddress.requestURL(show.feedURL),
               let fresh = await fetchForRefresh(url) {
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
        healStoredProgress()
        // The co-listened feeds ride in the same refresh, after the
        // subscriptions, under the same gate; never persisted like one.
        await CoListenedShows.refresh()
    }

    /// The refresh's fetch. A test replaces the network with
    /// `_testFeedFetcher`, the same seam `subscribe` uses, so a refresh can be
    /// driven and its publishes counted without a server.
    private func fetchForRefresh(_ url: URL) async -> PodcastShow? {
        if let fetcher = _testFeedFetcher {
            if case .show(let show) = await fetcher(url) { return show }
            return nil
        }
        return await Self.fetchAndParse(feedURL: url)
    }

    /// Give the EXISTING stock the reference point it was written without.
    ///
    /// The repair rode inside the gpodder pull. And that pull is incremental:
    /// it only sees episodes with a fresh server action. A stock that was
    /// imported once and never touched again carries a timestamp far older
    /// than any `since`, so the repair never reached a single one of those
    /// entries. Measured on a real device: about eighty finished episodes, not
    /// one of them with a reference point. They read correctly today only
    /// because no duration has grown yet. The day one does, they all fall
    /// back to "started" at once, and then nobody can heal them any more.
    ///
    /// So the pass runs over the LOCAL stock, where the feed durations already
    /// are, and it runs after every refresh: it is a few reads per episode, it
    /// is a no-op on entries that already carry their duration, and a marker
    /// would miss the episodes whose duration only appears in the feed later.
    private func healStoredProgress() {
        let writes = PodcastProgressHealing.writes(
            for: allEpisodes().map {
                PodcastProgressHealing.Episode(guid: $0.episode.guid, duration: $0.episode.duration)
            },
            stored: { ListeningStore.backup($0) })
        for (guid, entry) in writes {
            ListeningStore.store(guid, entry: entry)
        }
        if !writes.isEmpty {
            Logger.rss.notice("PODCAST healed \(writes.count) stored entries with the duration they were written against")
        }
    }

    /// Trim to the latest N episodes (0 = unlimited) and discard downloads of
    /// the removed episodes. Directly from the per-show settings.
    func trimEpisodes(showId: String, keepLatest n: Int) async {
        await ensureLoaded()
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

    /// All episodes of all shows, newest first (cached. Otherwise re-sorted
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

    /// Persist the current store (serialized, off-main. See `persist`). The
    /// old implementation encoded and wrote the whole JSON synchronously on the
    /// main actor: a visible hitch on subscribe/refresh/import.
    private func save() {
        // The central funnel. Persisting before the bootstrap
        // finished would write the still-empty RAM state over the good file
        // (the cold-start BGAppRefresh race). The mutation stays in RAM; the
        // callers below additionally await ensureLoaded() so this stays a
        // last-resort trap, not the working path.
        guard isLoaded else {
            Logger.rss.error("SUBSTORE save SKIPPED before bootstrap (cold-start race trapped)")
            return
        }
        persist(shows)
    }

    private func normalizedFeedURL(_ raw: String) -> URL? {
        PodcastFeedAddress.requestURL(raw)
    }

    // MARK: - Loading + Parsing

    // `@concurrent`: force this off the caller's executor. Under the project's
    // default MainActor isolation + NonisolatedNonsendingByDefault a plain
    // `nonisolated async` would run the network wait AND the XML parse on the
    // calling MainActor (callers at :284/:436 are main-actor). The parse is CPU
    // work that must not block the UI.
    /// Y2b: fetch + parse a feed WITHOUT persisting anything. The temporary
    /// show preview uses this; `subscribe` persists the result.
    @concurrent nonisolated static func fetchAndParse(feedURL rawURL: URL) async -> PodcastShow? {
        guard case .show(let show) = await fetchOutcome(feedURL: rawURL) else { return nil }
        return show
    }

    /// The same fetch, with the reason for a miss: the adoption path
    /// tells a sign-in demand from an outage.
    @concurrent nonisolated static func fetchOutcome(feedURL rawURL: URL) async -> FeedFetchOutcome {
        // THE funnel for every feed request. The rule sits here so a call
        // site that builds its own URL cannot get cleartext past it.
        let feedURL = PodcastFeedAddress.upgraded(rawURL)
        // Private/premium feeds: send the Basic auth header if stored.
        var request = URLRequest(url: feedURL)
        for (field, value) in PodcastFeedAuth.authHeader(feedKey: feedKey(feedURL.absoluteString)) {
            request.setValue(value, forHTTPHeaderField: field)
        }
        // Feed pulls ride the same retry policy as the ABS/Subsonic
        // clients (transient backoff, 401 probe for private feeds); a non-2xx
        // that survives the policy stays a miss like before, with its status.
        let data: Data
        let http: HTTPURLResponse?
        do {
            (data, http) = try await RequestRetryPolicy.fetch(request)
        } catch let error as URLError where error.code == .timedOut {
            return .failed(.timeout)
        } catch {
            return .failed(.unreachable)
        }
        if let status = http?.statusCode, !(200...299).contains(status) { return .status(status) }
        // The channel-level block tag travels with the feed.
        // Record it while we hold the bytes (no second request). Only a
        // POSITIVE finding is stored; an unreadable/short body must not
        // clear an earlier one.
        let head = String(decoding: data.prefix(FeedArtworkLookup.headByteCount), as: UTF8.self)
        if PodcastFeedBlock.isBlocked(feedHead: head) {
            noteFeedBlocked(feedURL.absoluteString)
        }
        let parser = RSSFeedParser(feedURL: feedURL.absoluteString)
        guard let show = parser.parse(data) else { return .failed(.unreadable) }
        return .show(show)
    }
}

/// What a feed fetch came back with. The reason of a miss matters to the
/// adoption path only; every other caller reads it as "no show".
nonisolated enum FeedFetchOutcome {
    case show(PodcastShow)
    /// A non-2xx answer that survived the retry policy.
    case status(Int)
    /// Transport failure (timeout, unreachable) or an unparseable body.
    case failed(FeedAdoptionPending.Reason)
}

/// Minimal RSS/Atom parser based on `XMLParser`. Covers the iTunes podcast
/// fields; unknown tags are ignored, broken items skipped. Internal (not
/// private). Covered by unit tests. `nonisolated`: pure CPU parsing, driven
/// off the main actor from `fetchAndParse` (@concurrent) and from tests.
nonisolated final class RSSFeedParser: NSObject, XMLParserDelegate {
    private let feedURL: String
    /// Stable, deterministic feed key (NOT `String.hashValue`, which is
    /// re-seeded per app start). Basis for show id and guids.
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
    /// Guids already emitted. Duplicate-guid items are dropped in-parse.
    private var seenGuids: Set<String> = []
    private var inItem = false
    /// Stehen wir gerade im RSS-Kanalbild (`<image><url>…</url></image>`)?
    private var inChannelImage = false
    private var text = ""
    /// The FIRST element of the document. A server can answer
    /// HTTP 200 with well-formed XML that is not a feed at all. Measured:
    /// podcastle.org/feed/podcast/ returned `<error><title>Database Error`,
    /// out of which this parser happily built a subscribable "show". Well-
    /// formedness is not feed-ness, so the root decides.
    private var rootElement: String?

    // Aktuelles Item
    private var iTitle = "", iGuid = "", iAudio = "", iDuration = "", iDesc = "", iImage = "", iPubDate = "", iChapters = ""
    /// `dc:date`/`updated` of the current item. Only used when the item has no `pubDate`.
    private var iDateFallback = ""
    private var iSeason: Int?, iEpisodeNum: Int?, iEpisodeType = "", iExplicit: Bool?, iLink = "", iTranscript = ""
    private var iPersons: [PodcastPerson] = []
    private var pendingPersonAttrs: [String: String]?

    /// Roots a feed may legitimately have: RSS 2.0, Atom, RDF-flavoured RSS 1.0.
    private static let feedRoots: Set<String> = ["rss", "feed", "rdf:RDF", "RDF"]

    func parse(_ data: Data) -> PodcastShow? {
        let parser = XMLParser(data: data)
        parser.delegate = self
        guard parser.parse() else { return nil }
        // Not a feed root ⇒ not a feed. No show is constructed from an
        // error page, however well-formed it is.
        guard let root = rootElement, Self.feedRoots.contains(root) else { return nil }
        // A "show" without a single episode AND without
        // artwork is not a show. Other 200-with-garbage shapes exist that a
        // root check alone would pass.
        guard !episodes.isEmpty || showImage != nil else { return nil }
        guard !showTitle.isEmpty || !episodes.isEmpty else { return nil }
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
        if rootElement == nil { rootElement = qName ?? el }
        text = ""
        if el == "item" || el == "entry" {
            inItem = true
            iTitle = ""; iGuid = ""; iAudio = ""; iDuration = ""; iDesc = ""; iImage = ""; iPubDate = ""; iChapters = ""; iDateFallback = ""
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
        // Person (name follows as text content). Remember the attributes now.
        if el == "podcast:person" { pendingPersonAttrs = attrs }
        // Funding (label follows as text). Remember the URL.
        if el == "podcast:funding" { pendingFundingURL = attrs["url"] }
        // Categories (also nested: parent + child both fire).
        if el == "itunes:category", !inItem, let cat = attrs["text"], !showCategories.contains(cat) {
            showCategories.append(cat)
        }
        // Enclosure (RSS). Acceptance incl. video/octet-stream, see
        // `acceptsEnclosure`. Without it Podsync feeds parse empty.
        if el == "enclosure", let url = attrs["url"],
           Self.acceptsEnclosure(type: attrs["type"], url: url) {
            iAudio = Self.resolved(url, against: feedURL)
        }
        // itunes:image / channel image via href attribute, resolved against
        // the feed base. Relative artwork URLs occur in the wild.
        if el == "itunes:image", let href = attrs["href"] {
            let resolved = Self.resolved(href, against: feedURL)
            if inItem { iImage = resolved } else if showImage == nil { showImage = resolved }
        }
        // A feed can name its image TWICE and this reader found neither. It
        // did not read the RSS form `<image><url>…</url></image>` at all, and
        // the itunes form WITHOUT `href` (the URL as element text) fell
        // through because the attribute is empty. `FeedArtworkLookup` already
        // understood the RSS form: two readers, one spelling, one of them
        // knows more.
        //
        // INVARIANT: a spelling the app understands in ONE place, it
        // understands everywhere.
        if el == "image", !inItem { inChannelImage = true }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }

    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        if let s = String(data: CDATABlock, encoding: .utf8) { text += s }
    }

    func parser(_ parser: XMLParser, didEndElement el: String, namespaceURI: String?, qualifiedName qName: String?) {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // The two spellings this reader did not know.
        if el == "image", !inItem { inChannelImage = false }
        if el == "url", inChannelImage, !inItem, showImage == nil, !value.isEmpty {
            showImage = Self.resolved(value, against: feedURL)
        }
        if el == "itunes:image", !value.isEmpty {
            let resolved = Self.resolved(value, against: feedURL)
            if inItem { if iImage.isEmpty { iImage = resolved } }
            else if showImage == nil { showImage = resolved }
        }
        // Closing a person (name = text content). Possible in item and channel.
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
            // `dc:date` (Dublin Core) and Atom's `updated` carry the date in
            // feeds that never write `pubDate`. Without them every episode of
            // such a feed got date 0. `pubDate`/`published` still WIN: the
            // first non-empty one stays, so a feed carrying both keeps its
            // publication date instead of its last edit.
            case "pubDate", "published": iPubDate = value
            // `dc:date` (Dublin Core) and Atom's `updated` carry the date in
            // feeds that never write `pubDate`. Kept APART instead of into the
            // same slot: the order of elements inside an item is not
            // guaranteed, so „first one wins" would let the edit date beat the
            // publication date in a feed that carries both. The choice is made
            // where the episode is built, not where the text arrives.
            case "dc:date", "updated": iDateFallback = value
            case "itunes:season": iSeason = Int(value)
            case "itunes:episode": iEpisodeNum = Int(value)
            case "itunes:episodeType": iEpisodeType = value.lowercased()
            case "itunes:explicit": iExplicit = Self.parseExplicit(value)
            case "link": if iLink.isEmpty { iLink = value }
            case "item", "entry":
                inItem = false
                // Duplicate guids collapse HERE (first item wins. Feeds
                // list newest first); duplicates used to survive the first
                // subscribe and collide as SwiftUI ids.
                // Items WITHOUT an audio
                // enclosure are KEPT. Dimmed, no play affordance, tap opens
                // the show notes (Apple-Podcasts behaviour). Text-only feeds
                // no longer look empty/broken. Identity falls back to the
                // link, then the title (an item with none of guid/audio/link/
                // title has no stable identity and is skipped).
                let fallbackId = iGuid.isEmpty ? (iAudio.isEmpty ? (iLink.isEmpty ? iTitle : iLink) : iAudio) : iGuid
                let guid = "rss:\(feedKey):\(fallbackId)"
                if !fallbackId.isEmpty, seenGuids.insert(guid).inserted {
                    episodes.append(PodcastEpisode(
                        guid: guid,
                        title: iTitle.isEmpty ? String(localized: "Untitled Episode") : iTitle,
                        audioURL: iAudio,
                        pubDate: Self.parseDate(iPubDate.isEmpty ? iDateFallback : iPubDate),
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

    // MARK: - Pure helpers (unit-tested)

    /// Which enclosures carry playable media. `audio/*` and `video/*`
    /// play directly (AVPlayer takes the audio track of a video enclosure.
    /// Podsync's YouTube→RSS feeds ship `video/mp4`); the very common
    /// `application/octet-stream` lie is accepted when the file extension
    /// looks like media. Missing type keeps counting as audio (prior
    /// behaviour). Everything else (text/html, image/…) is rejected.
    static let mediaExtensions: Set<String> = [
        "mp3", "m4a", "m4b", "aac", "ogg", "oga", "opus", "wav", "flac",
        "mp4", "m4v", "mov", "webm",
    ]
    nonisolated static func acceptsEnclosure(type: String?, url: String) -> Bool {
        guard let type, !type.isEmpty else { return true }
        let lower = type.lowercased()
        if lower.hasPrefix("audio") || lower.hasPrefix("video") { return true }
        if lower == "application/octet-stream" {
            let ext = (URL(string: url)?.pathExtension ?? (url as NSString).pathExtension).lowercased()
            return mediaExtensions.contains(ext)
        }
        return false
    }

    /// Resolve a possibly-relative media/artwork URL against the feed
    /// URL. Absolute URLs pass through untouched; unresolvable input is
    /// returned as-is (never worse than before).
    nonisolated static func resolved(_ raw: String, against base: String) -> String {
        guard URL(string: raw)?.scheme == nil else { return raw }
        guard let baseURL = URL(string: base),
              let resolved = URL(string: raw, relativeTo: baseURL) else { return raw }
        return resolved.absoluteString
    }

    // RFC822-Datum → ms epoch (Fallback: 0). The wild also ships the
    // weekday-less form and zone NAMES (EST/GMT). One formatter chain,
    // built once (DateFormatter creation is expensive).
    //
    // The seconds are OPTIONAL in RFC 822, and feeds ship both. A date the
    // chain cannot read falls back to 0, and a zero date is not a cosmetic
    // loss: the podcast tab admits a show only when its newest episode has a
    // date, so a feed whose dates are unreadable becomes a subscription that
    // stands in the settings list and is invisible in the tab, WITH its
    // episode count. That is why this chain is wider than it looks.
    private static let dateFormatters: [DateFormatter] = [
        "EEE, dd MMM yyyy HH:mm:ss Z",
        "dd MMM yyyy HH:mm:ss Z",
        "EEE, dd MMM yyyy HH:mm:ss zzz",
        "dd MMM yyyy HH:mm:ss zzz",
        "EEE, dd MMM yyyy HH:mm Z",
        "dd MMM yyyy HH:mm Z",
        "EEE, dd MMM yyyy HH:mm zzz",
        "dd MMM yyyy HH:mm zzz",
    ].map { format in
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = format
        return f
    }

    private static func parseDate(_ s: String) -> Double {
        for f in dateFormatters {
            if let d = f.date(from: s) { return d.timeIntervalSince1970 * 1000 }
        }
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
