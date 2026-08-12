// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

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
    /// Pinchflat Paket A/B (5c8ff27 c): provenance — which server MIRRORS
    /// this feed (PinchflatMirror.originTag). nil = an ordinary subscription.
    /// Herkunft ist ein Fakt am Feed, kein zweiter Ordnungsbaum.
    var origin: String? = nil
    var showType: String? = nil    // episodic | serial
}

nonisolated struct PodcastEpisode: Codable, Identifiable {
    var guid: String
    var title: String
    var audioURL: String
    var pubDate: Double             // ms epoch
    var duration: Double            // seconds (0 if unknown) — FEED-Tatsache
    /// The length MEASURED from the asset. It is a STORE fact: a fresh parse
    /// cannot know it, because it only comes into existence during playback.
    /// Hence its own field — while it merely overwrote `duration` it was
    /// indistinguishable from the feed's claim and died on every refresh.
    /// `duration` still mirrors it so every reader sees the best known length.
    var measuredDuration: Double? = nil
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

    /// R1 (01.08): an item without an audio enclosure is KEPT as a text-only
    /// episode — visible (dimmed, show notes on tap) but never playable,
    /// queueable, downloadable or markable as played.
    var isPlayable: Bool { !audioURL.isEmpty }
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
        // Befund T1: mirror the origin-carrying feed keys into the defaults
        // set the nonisolated premium truth reads — ONE maintenance point,
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
    /// init — on the main actor, BEFORE first paint (the singleton is created
    /// by the first observing view). The decode now runs off-main; the UI
    /// starts empty and fills one tick later. Startup callers that need the
    /// episode index (session restore, CarPlay) await `ensureLoaded()`.
    private var bootstrapTask: Task<Void, Never>?

    /// 593d177: true once the bootstrap disk load finished (EVERY path) —
    /// save() refuses to persist before that, so a cold-start mutation can
    /// never wipe the good file with the still-empty in-memory state.
    private(set) var isLoaded = false

    private init() {
        let url = fileURL
        bootstrapTask = Task { [weak self] in
            // V2 audit fix: "file missing" (fresh install) and "file present
            // but UNDECODABLE" (corruption) must not look the same — the old
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
            // 593d177 (5): startup diagnosis — a future loss must be READABLE
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
    /// encode+write run off-main, and each write awaits the previous one — two
    /// overlapping detached writes could otherwise interleave and corrupt the
    /// JSON. Writes take a value snapshot, so later mutations of `shows` don't
    /// affect an in-flight write.
    private let writeChain = SerializedWriteChain()

    /// 593d177 (2): consumed one-shot flag — ONLY a user-initiated path
    /// (last unsubscribe) may legitimately write an EMPTY store over a
    /// non-empty file.
    private var userInitiatedEmptyWrite = false

    private func persist(_ snapshot: [PodcastShow]) {
        // 593d177: last line of defense — an EMPTY snapshot never overwrites
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

    /// R1 (01.08): THE ONE playability check for episode item ids. Text-only
    /// rss: episodes (kept in the list, no enclosure) are never playable/
    /// queueable/downloadable; non-rss ids (abspod:, books, music) always are
    /// from this check's point of view.
    func isPlayableEpisode(itemId: String) -> Bool {
        guard itemId.hasPrefix("rss:") else { return true }
        guard let found = episode(guid: itemId) else { return true }
        return found.episode.isPlayable
    }

    #if DEBUG
    /// UI-test seeding only (see UITestSeed) — injects deterministic shows.
    func _seedForUITest(_ shows: [PodcastShow]) { self.shows = shows }
    /// 593d177 test seams: drive the wipe guard + load gate deterministically.
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
    /// bb89772: "freebie" joined after the ZEIT leak finding (their premium
    /// class uses `freebie=<token>`) — ONE set feeds detection, masking AND
    /// the OPML-export guard.
    nonisolated static let secretQueryParams: Set<String> =
        ["token", "auth", "key", "secret", "freebie"]

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
    /// premium test has ONE home). 6446a04: the membership hosters whose
    /// personalised URLs carry the token in the PATH — pure data.
    nonisolated private static let premiumHosts =
        ["patreon.com", "supercast", "supportingcast", "memberful", "acast.com/access",
         "supportingcast.fm", "supercast.com", "memberful.com", "steadyhq.com"]

    /// 6446a04: feeds whose CHANNEL states `<itunes:block>`/`<podcast:block>`
    /// — the standard "do not list publicly" signal. Persisted per feed key,
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
    }

    nonisolated static func isFeedBlocked(_ feedURL: String,
                                          defaults: UserDefaults = .standard) -> Bool {
        blockedFeedKeys(defaults: defaults).contains(feedKey(feedURL))
    }

    /// THE premium test: stored basic-auth credentials OR the token-URL class
    /// OR a known members-only host OR a MANUAL user marking (92e25d6 — the
    /// escape hatch for unknown patterns; one truth feeds management, tab
    /// grouping, badges, the replace dialog AND the OPML-export guard).
    nonisolated static func isPremiumFeed(_ feedURL: String,
                                          defaults: UserDefaults = .standard) -> Bool {
        // Befund T1: a mirrored feed is NEVER premium — its host login is
        // server infrastructure, not a paywall; its marking is the origin
        // capsule. First check, so no heuristic below can override it.
        if mirroredFeedKeys(defaults: defaults).contains(feedKey(feedURL)) { return false }
        if PodcastFeedAuth.hasCredentials(feedKey: feedKey(feedURL)) { return true }
        if isTokenFeedURL(feedURL) { return true }
        // 6446a04: the feed says it itself — catches the path-token class
        // the query-param heuristic cannot see.
        if isFeedBlocked(feedURL) { return true }
        if manualPremiumFeedKeys().contains(feedKey(feedURL)) { return true }
        let lower = feedURL.lowercased()
        return premiumHosts.contains { lower.contains($0) }
    }

    /// Befund T1: the mirrored-group feed keys (maintained in rebuildCaches).
    nonisolated static func mirroredFeedKeys(defaults: UserDefaults = .standard) -> Set<String> {
        Set(defaults.stringArray(forKey: AppStorageKeys.pinchflatMirroredFeedKeys) ?? [])
    }

    /// 92e25d6: manual premium markings (persisted feed keys).
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
        if marked { keys.insert(feedKey(feedURL)) } else { keys.remove(feedKey(feedURL)) }
        defaults.set(Array(keys).sorted(), forKey: AppStorageKeys.premiumMarkedFeeds)
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

    /// f4f1b46: identity WITHOUT the secret VALUES — the ZEIT class rotates
    /// its `freebie` token, and since the token joined the identity params
    /// (bb89772) a rotated token spawned a TWIN of the same feed (the
    /// screenshot: two entries, identical masked URL). Same masked identity
    /// ⇒ same resource on one device.
    nonisolated static func collapseKey(_ feedURL: String) -> String {
        stableHash(maskedFeedURL(normalizeFeedURL(feedURL)))
    }

    /// Pure migration core (testable): re-key ids/guids, report every progress
    /// move via `moveProgress(old, new)`, dedupe shows of the same feed —
    /// stage 1 on the exact identity, stage 2 (f4f1b46) on the MASKED
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

        // Stage 2 (f4f1b46): collapse token-rotation twins (same MASKED id).
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
        // Argument-Reihenfolge mit Absicht: Der ZWEITE gewinnt die
        // Feed-Tatsachen, und das muss hier der Ueberlebende sein — seine URL
        // traegt den aktuellen Token. Die Speicher-Tatsachen ueberleben von
        // beiden Seiten (siehe merge), der Verlierer verliert also nur seine
        // veraltete Adresse.
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

    /// Zwei Fassungen derselben Sendung zusammenführen: Folgen als Vereinigung
    /// nach `guid`, neueste zuerst. `internal`, damit die RSS-Härtung (bei
    /// einem dünnen Abruf nie schrumpfen) im Unit-Test fahrbar ist.
    ///
    /// **Classify fields instead of picking a side.**
    ///
    /// Picking the side with more episodes and then patching individual fields
    /// back requires someone to remember every field, every time — two fields
    /// died that way before.
    ///
    /// The classification is objective, not a judgement call:
    ///  * **Feed-Tatsachen** (Titel, Bild, Beschreibung, Kategorien, die
    ///    angekuendigte Dauer): das frische Parsen kennt sie am besten, die
    ///    frische Seite gewinnt.
    ///  * **Speicher-Tatsachen** (`origin`, die gemessene Assetlaenge): ein
    ///    frisches Parsen kann sie GAR NICHT kennen — sie ueberleben von der
    ///    gespeicherten Seite, unabhaengig davon, wer mehr Folgen hat.
    ///
    /// Die Folgenliste bleibt eine Vereinigung nach `guid`: ein duennes Parsen
    /// (gueltiger Titel, wenige Folgen) darf den Zwischenspeicher nie leeren.
    /// Und bei doppelter `guid` zieht die Klassifizierung auf FOLGEN-Ebene mit
    /// — sonst stuerbe dieselbe Tatsache nur unauffaelliger.
    ///
    /// Die Speicher-Tatsachen werden nicht blind von `stored` genommen,
    /// sondern „wer sie hat, behaelt sie" (`stored ?? fresh`). Beim
    /// Auffrischen ist das dasselbe, weil ein frisches Parsen sie nie hat —
    /// aber `collapseInto` benutzt denselben Merge, um einen Zwillings-Eintrag
    /// in den ueberlebenden zu falten, und dort darf die Herkunft des
    /// Verlierers nicht verlorengehen, nur weil er als zweites Argument steht.
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

    /// Was nur der Speicher ueber eine FOLGE weiss. Waechst diese Liste, muss
    /// der Zaun `storeFactsSurviveARefresh` mitwachsen — er ist genau dafuer da.
    private nonisolated static func carryStoreFacts(from stored: PodcastEpisode,
                                                    into fresh: inout PodcastEpisode) {
        // Nur wenn die andere Seite selbst keine Messung traegt — sonst waere
        // ein aelterer Wert staerker als ein neuerer.
        if fresh.measuredDuration == nil, let measured = stored.measuredDuration, measured > 0 {
            fresh.measuredDuration = measured
            // Gespiegelt, damit jede Lesestelle die beste bekannte Laenge sieht.
            fresh.duration = measured
        }
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
        await ensureLoaded()   // 593d177: no mutation before the disk load
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = normalizedFeedURL(trimmed) else { return false }
        guard let show = await Self.fetchAndParse(feedURL: url) else { return false }
        if let idx = shows.firstIndex(where: { $0.id == show.id }) {
            // Re-subscribe must not blindly replace: a weak parse (valid title,
            // few/zero episodes) would drop the cached episodes. Union instead.
            shows[idx] = Self.merge(shows[idx], show)
        } else {
            shows.insert(show, at: 0)
            // Y51→97b1f7c: a NEW premium feed of ANY class (credentials,
            // token URL, members host, manual mark — the ZEIT case never
            // triggered because only credentials counted) that looks like an
            // existing free subscription → offer the replacement.
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

    /// Pinchflat Paket A: tag a mirrored feed's provenance.
    func setOrigin(_ origin: String?, forFeedURL feedURL: String) {
        guard let index = shows.firstIndex(where: { $0.feedURL == feedURL }) else { return }
        shows[index].origin = origin
        save()
    }

    /// Paket B: every episode guid of the mirrored group — hosts resolve
    /// membership ONCE per render and hand rows a Bool (cell-cost rule:
    /// no per-row shows×episodes scan).
    func mirroredEpisodeGuids() -> Set<String> {
        Set(shows.filter { $0.origin != nil }.flatMap { $0.episodes.map(\.guid) })
    }

    /// Paket B: does this feed belong to a mirrored group? Carried by the
    /// `origin` field only — never a URL heuristic (a916a5a). Drives the
    /// "YouTube" origin capsule on surfaces OUTSIDE the group row.
    func isMirrored(feedURL: String) -> Bool {
        let normalized = Self.normalizeFeedURL(feedURL)
        return shows.contains {
            $0.origin != nil && Self.normalizeFeedURL($0.feedURL) == normalized
        }
    }

    /// Pinchflat Paket A: a SERVER-driven remove (channel left the mirror).
    /// Deliberately NOT the user-unsubscribe: it must not join the gpodder
    /// user-intent set — the mirrored group is no subscription set of the
    /// user's (a7fa35e), and progress stays like any unsubscribe.
    func removeMirrored(feedURL: String) {
        shows.removeAll { $0.feedURL == feedURL }
        save()
    }

    func unsubscribe(id: String) {
        // 593d177 (2)+(R2): a user unsubscribe may legitimately empty the
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

    /// R2: normalized URLs the USER unsubscribed — the only removes the
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
        await ensureLoaded()   // 593d177
        guard AppStorageKeys.podcastIndexConfigured,
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
    }

    /// Import an OPML file: subscribe to every `xmlUrl` feed (no progress).
    /// `nil` when the file is not well-formed OPML/XML (O1: visible failure
    /// instead of a silent partial import).
    func importOPML(_ data: Data) async -> ImportResult? {
        guard let feeds = PodcastImport.parseOPML(data) else { return nil }
        var result = ImportResult()
        for feed in feeds {
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
        // Listen log: the import wrote positions past the played threshold —
        // re-scan the (now-subscribed) shows with full metadata (fixlet
        // 4575a76; targeted rescan, not the one-time backfill flag).
        PodcastListenLog.shared.rescan(shows: shows)
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
    /// The latest known length of an episode — after playback the one MEASURED
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
        // In BEIDE Felder: `duration` bleibt die beste bekannte Laenge fuer
        // jede Lesestelle, `measuredDuration` ist die Speicher-Tatsache, die
        // der Merge ueber die naechste Auffrischung rettet.
        shows[idx.show].episodes[idx.episode].duration = duration
        shows[idx.show].episodes[idx.episode].measuredDuration = duration
        save()
    }

    /// Reload all feeds (pull-to-refresh). Failed ones keep their cached state.
    func refreshAll() async {
        // 593d177 (1): NEVER mutate before the disk load — the BGAppRefresh
        // cold start hit exactly this window and wiped the store.
        await ensureLoaded()
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
        healStoredProgress()
    }

    /// Give the EXISTING stock the reference point it was written without.
    ///
    /// The repair rode inside the gpodder pull — and that pull is incremental:
    /// it only sees episodes with a fresh server action. A stock that was
    /// imported once and never touched again carries a timestamp far older
    /// than any `since`, so the repair never reached a single one of those
    /// entries. Measured on a real device: about eighty finished episodes, not
    /// one of them with a reference point. They read correctly today only
    /// because no duration has grown yet — the day one does, they all fall
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
            stored: { defaults.array(forKey: AppStorageKeys.localPosition($0)) as? [Double] })
        for (guid, entry) in writes {
            defaults.set(entry, forKey: AppStorageKeys.localPosition(guid))
        }
        if !writes.isEmpty {
            Logger.rss.notice("PODCAST healed \(writes.count) stored entries with the duration they were written against")
        }
    }

    /// Trim to the latest N episodes (0 = unlimited) and discard downloads of
    /// the removed episodes. Directly from the per-show settings.
    func trimEpisodes(showId: String, keepLatest n: Int) async {
        await ensureLoaded()   // 593d177
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
        // 593d177 (1): the central funnel — persisting before the bootstrap
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
        // 6446a04: the channel-level block tag travels with the feed —
        // record it while we hold the bytes (no second request). Only a
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
    /// R4: guids already emitted — duplicate-guid items are dropped in-parse.
    private var seenGuids: Set<String> = []
    private var inItem = false
    private var text = ""
    /// B1 (09.08.): the FIRST element of the document. A server can answer
    /// HTTP 200 with well-formed XML that is not a feed at all — measured:
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
        // B1: not a feed root ⇒ not a feed. No show is constructed from an
        // error page, however well-formed it is.
        guard let root = rootElement, Self.feedRoots.contains(root) else { return nil }
        // B2 (belt and braces): a "show" without a single episode AND without
        // artwork is not a show — other 200-with-garbage shapes exist that a
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
        // Person (name follows as text content) — remember the attributes now.
        if el == "podcast:person" { pendingPersonAttrs = attrs }
        // Funding (label follows as text) — remember the URL.
        if el == "podcast:funding" { pendingFundingURL = attrs["url"] }
        // Categories (also nested: parent + child both fire).
        if el == "itunes:category", !inItem, let cat = attrs["text"], !showCategories.contains(cat) {
            showCategories.append(cat)
        }
        // Enclosure (RSS) — acceptance incl. video/octet-stream, see
        // `acceptsEnclosure` (Korpus-Befund R2: Podsync feeds parsed empty).
        if el == "enclosure", let url = attrs["url"],
           Self.acceptsEnclosure(type: attrs["type"], url: url) {
            iAudio = Self.resolved(url, against: feedURL)
        }
        // itunes:image / channel image via href attribute (R3: resolved
        // against the feed base — relative artwork URLs occur in the wild).
        if el == "itunes:image", let href = attrs["href"] {
            let resolved = Self.resolved(href, against: feedURL)
            if inItem { iImage = resolved } else if showImage == nil { showImage = resolved }
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
                // R4: duplicate guids collapse HERE (first item wins — feeds
                // list newest first); duplicates used to survive the first
                // subscribe and collide as SwiftUI ids.
                // Items WITHOUT an audio
                // enclosure are KEPT — dimmed, no play affordance, tap opens
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

    // MARK: - Pure helpers (Korpus-Härtung R2/R3, unit-tested)

    /// R2: which enclosures carry playable media. `audio/*` and `video/*`
    /// play directly (AVPlayer takes the audio track of a video enclosure —
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

    /// R3: resolve a possibly-relative media/artwork URL against the feed
    /// URL. Absolute URLs pass through untouched; unresolvable input is
    /// returned as-is (never worse than before).
    nonisolated static func resolved(_ raw: String, against base: String) -> String {
        guard URL(string: raw)?.scheme == nil else { return raw }
        guard let baseURL = URL(string: base),
              let resolved = URL(string: raw, relativeTo: baseURL) else { return raw }
        return resolved.absoluteString
    }

    // RFC822-Datum → ms epoch (Fallback: 0). R5: the wild also ships the
    // weekday-less form and zone NAMES (EST/GMT) — one formatter chain,
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
