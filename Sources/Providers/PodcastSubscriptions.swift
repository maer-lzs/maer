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
        didSet { rebuildCaches() }
    }

    /// Set when a new premium subscription matches an existing free one;
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
        // Mirror the origin-carrying feed keys into the defaults
        // set the nonisolated premium truth reads. ONE maintenance point,
        // always in sync with the store (bootstrap heals existing stores).
        let mirrored = Set(shows.filter { $0.origin != nil }.map { Self.feedKey($0.feedURL) })
        if mirrored != Self.mirroredFeedKeys() {
            UserDefaults.standard.set(Array(mirrored).sorted(),
                                      forKey: AppStorageKeys.pinchflatMirroredFeedKeys)
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
        bootstrapTask = Task { [weak self] in
            // "file missing" (fresh install) and "file present
            // but UNDECODABLE" (corruption) must not look the same. The old
            // ?? [] made a corrupt store start empty, and the NEXT persist()
            // silently overwrote the recoverable data with that empty list.
            // A corrupt file is preserved as .corrupt and loudly logged.
            let decoded = await Task.detached(priority: .userInitiated) { () -> [PodcastShow]? in
                guard let data = try? Data(contentsOf: url) else { return [] }   // missing → fresh
                if let shows = try? JSONDecoder().decode([PodcastShow].self, from: data) {
                    return shows
                }
                let backup = url.appendingPathExtension("corrupt")
                try? FileManager.default.removeItem(at: backup)
                try? FileManager.default.moveItem(at: url, to: backup)
                return nil
            }.value
            if decoded == nil {
                Logger.rss.error("subscriptions store undecodable — preserved as .corrupt, starting empty")
            }
            // Startup diagnosis. A future loss must be READABLE
            // from the log, not reconstructed.
            let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
            let size = (attrs?[.size] as? Int) ?? 0
            let mtime = (attrs?[.modificationDate] as? Date)?.description ?? "-"
            let corruptExists = FileManager.default.fileExists(atPath: url.appendingPathExtension("corrupt").path)
            Logger.rss.notice("SUBSTORE bootstrap: size=\(size)B mtime=\(mtime, privacy: .public) shows=\(decoded?.count ?? -1) corruptBackup=\(corruptExists)")
            defer { self?.isLoaded = true }   // EVERY exit path unlocks save()
            guard let self, let decoded, !decoded.isEmpty else { return }
            self.shows = self.migrated(decoded)
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
    func feedURL(forEpisodeId episodeId: String) -> String? {
        shows.first { $0.episodes.contains { $0.guid == episodeId } }?.feedURL
    }

    func ensureLoaded() async {
        await bootstrapTask?.value
    }

    // MARK: - Serialized disk writes

    /// All writes to the store file are CHAINED (see `SerializedWriteChain`):
    /// encode+write run off-main, and each write awaits the previous one. Two
    /// overlapping detached writes could otherwise interleave and corrupt the
    /// JSON. Writes take a value snapshot, so later mutations of `shows` don't
    /// affect an in-flight write.
    private let writeChain = SerializedWriteChain()

    /// Consumed one-shot flag. ONLY a user-initiated path
    /// (last unsubscribe) may legitimately write an EMPTY store over a
    /// non-empty file.
    private var userInitiatedEmptyWrite = false

    private func persist(_ snapshot: [PodcastShow]) {
        // Last line of defense. An EMPTY snapshot never overwrites
        // a non-empty file unless the user explicitly emptied the list.
        // Refuse loudly + drop a tombstone note so the NEXT incident is
        // diagnosable instead of traceless (log-first).
        if snapshot.isEmpty, !userInitiatedEmptyWrite {
            let size = ((try? FileManager.default.attributesOfItem(atPath: fileURL.path))?[.size] as? Int) ?? 0
            if size > 2 {   // "[]" is 2 bytes — anything bigger holds data
                Logger.rss.error("SUBSTORE wipe REFUSED: empty snapshot over \(size)B file without user intent")
                let note = "wipe refused at \(Date()) — empty snapshot, file \(size)B, isLoaded=\(isLoaded)\n"
                let tombstone = fileURL.appendingPathExtension("wipe-refused.txt")
                try? note.data(using: .utf8)?.write(to: tombstone)
                return
            }
        }
        userInitiatedEmptyWrite = false
        writeChain.write(to: fileURL) {
            try? JSONEncoder().encode(snapshot)
        }
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
    nonisolated static let secretQueryParams: Set<String> =
        ["token", "auth", "key", "secret", "freebie"]

    nonisolated private static let identityQueryParams: Set<String> =
        secretQueryParams.union(["id", "show", "feed", "user", "podcast"])

    /// Token-URL premium class. A known secret parameter with a non-empty
    /// value. Conservative string parse (works for raw AND normalized URLs).
    nonisolated static func isTokenFeedURL(_ raw: String) -> Bool {
        guard let q = raw.firstIndex(of: "?") else { return false }
        return raw[raw.index(after: q)...].split(separator: "&").contains { pair in
            let parts = pair.split(separator: "=", maxSplits: 1)
            return parts.count == 2 && !parts[1].isEmpty
                && secretQueryParams.contains(parts[0].lowercased())
        }
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
    private nonisolated static func originalGuid(_ guid: String) -> String {
        let parts = guid.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false)
        if parts.count == 3, parts[0] == "rss" { return String(parts[2]) }
        return guid
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
    func subscribe(urlString: String) async -> Bool {
        await ensureLoaded()   // No mutation before the disk load
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = normalizedFeedURL(trimmed) else { return false }
        guard let show = await Self.fetchAndParse(feedURL: url) else { return false }
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
            let defaults = UserDefaults.standard
            for (freeGuid, premiumGuid) in matches {
                guard let stored = ListeningStore.backup(freeGuid, in: defaults),
                      !ListeningStore.hasStand(premiumGuid, in: defaults) else { continue }
                ListeningStore.store(premiumGuid, entry: stored, in: defaults)
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
        let defaults = UserDefaults.standard
        for (freeGuid, premiumGuid) in matches {
            if ListeningStore.hasStand(freeGuid, in: defaults) {
                // ONE re-keying, one rule. This used to be a second
                // implementation beside the stock's: it SKIPPED any occupied
                // target, so an OLDER stand there was never healed. The same
                // defect as the unconditional overwrite, turned the other way.
                ListeningStore.move(from: freeGuid, to: premiumGuid, in: defaults)
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

    func unsubscribe(id: String) {
        // A user unsubscribe may legitimately empty the
        // store; the normalized URL joins the user-intent set so the gpodder
        // sync may propagate THIS single remove immediately (derived removes
        // wait for the two-sync confirmation instead).
        if let show = shows.first(where: { $0.id == id }) {
            Self.recordUserRemovedFeed(Self.normalizeFeedURL(show.feedURL))
        }
        shows.removeAll { $0.id == id }
        if shows.isEmpty { userInitiatedEmptyWrite = true }
        save()
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
        /// States that met a newer or finished local entry and stayed out.
        var keptLocal = 0
        /// Titles of the states no episode claimed. Named, not only
        /// counted, so a half success is visible.
        var unmatched: [String] = []
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
                guard let entry = ListeningStore.backup(episode.guid), let position = entry.first else { continue }
                let finished = ProgressMark.isPlayed(stored: entry, currentDuration: episode.duration)
                guard finished || position > 1 else { continue }
                states.append(ForeignListeningState(
                    feedURL: show.feedURL,
                    episodeGUID: ForeignStateMatcher.rawGUID(storedGUID: episode.guid),
                    enclosureURL: episode.audioURL.isEmpty ? nil : episode.audioURL,
                    episodeLink: episode.link,
                    episodeTitle: episode.title,
                    position: position >= ProgressMark.playedSentinel ? 0 : position,
                    duration: episode.duration > 0 ? episode.duration : nil,
                    finished: finished,
                    stampedAt: ProgressMark.timestamp(entry)))
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
            if await subscribe(urlString: feed) {
                if lastFreeTwinSkip != nil { result.freeTwinsSkipped += 1 } else { result.subscribed += 1 }
            } else { result.failed += 1 }
        }
        result.paidSkipped = library.unimportablePaidCount
        guard !library.states.isEmpty else { return result }
        let outcome = applyForeignStates(library.states)
        result.progressApplied = outcome.applied
        result.keptLocal = outcome.keptLocal
        result.unmatched = outcome.unmatched
        // Listen log: the import wrote positions past the played threshold.
        // Re-scan the (now-subscribed) shows with full metadata. A
        // targeted rescan, not the one-time backfill flag.
        PodcastListenLog.shared.rescan(shows: shows)
        return result
    }

    /// Maps foreign states onto our episodes through the ladder and writes
    /// what the conflict rule admits into `localPosition`, the store the
    /// player uses. The plan carries one state per episode; duplicates in
    /// the source were reduced before the rule, so the file order cannot
    /// change where an episode ends.
    private func applyForeignStates(_ states: [ForeignListeningState])
        -> (applied: Int, keptLocal: Int, unmatched: [String]) {
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
        var keptLocal = 0
        var steps: [ForeignStateMatcher.Step: Int] = [:]
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
            guard let entry = ForeignStateMerge.adopt(
                local: ListeningStore.backup(match.targetID),
                foreign: match.state,
                duration: duration) else { keptLocal += 1; continue }
            ListeningStore.store(match.targetID, entry: entry)
            applied += 1
        }
        let unmatched = plan.unmatched.map { $0.episodeTitle ?? $0.enclosureURL ?? $0.episodeLink ?? "?" }
        let rungs = ForeignStateMatcher.Step.allCases.map { "\($0.rawValue)=\(steps[$0] ?? 0)" }.joined(separator: " ")
        Logger.rss.notice("FOREIGN import: applied=\(applied) \(rungs, privacy: .public) localKept=\(keptLocal) unmatched=\(unmatched.count)")
        if applied > 0 {
            shows = updated
            save()
            PodcastProgressStore.shared.reload()
        }
        return (applied, keptLocal, unmatched)
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
               let fresh = await Self.fetchAndParse(feedURL: url) {
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
        let defaults = UserDefaults.standard
        let writes = PodcastProgressHealing.writes(
            for: allEpisodes().map {
                PodcastProgressHealing.Episode(guid: $0.episode.guid, duration: $0.episode.duration)
            },
            stored: { ListeningStore.backup($0, in: defaults) })
        for (guid, entry) in writes {
            ListeningStore.store(guid, entry: entry, in: defaults)
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
        // that survives the policy stays a nil result like before.
        guard let (data, http) = try? await RequestRetryPolicy.fetch(request) else { return nil }
        if let status = http?.statusCode, !(200...299).contains(status) { return nil }
        // The channel-level block tag travels with the feed.
        // Record it while we hold the bytes (no second request). Only a
        // POSITIVE finding is stored; an unreadable/short body must not
        // clear an earlier one.
        let head = String(decoding: data.prefix(FeedArtworkLookup.headByteCount), as: UTF8.self)
        if PodcastFeedBlock.isBlocked(feedHead: head) {
            noteFeedBlocked(feedURL.absoluteString)
        }
        let parser = RSSFeedParser(feedURL: feedURL.absoluteString)
        return parser.parse(data)
    }
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
            case "pubDate", "published": iPubDate = value
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
    private static let dateFormatters: [DateFormatter] = [
        "EEE, dd MMM yyyy HH:mm:ss Z",
        "dd MMM yyyy HH:mm:ss Z",
        "EEE, dd MMM yyyy HH:mm:ss zzz",
        "dd MMM yyyy HH:mm:ss zzz",
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
