// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation
import UIKit
import OSLog

/// e4bd910: the radio-logo fallback chain BEHIND the gated favicon —
/// Wikidata P154 first, then the homepage apple-touch-icon, then nothing
/// (placeholder). Reuses the portrait chain's manners: identifying UA,
/// ~1 req/s politeness, session cache INCLUDING negatives (a no-hit never
/// re-asks), opt-out on the network-services page (`radioLogoChainEnabled`).
/// Images ride the shared ImageCache (persistent).
actor RadioLogoService {
    static let shared = RadioLogoService()

    private var cache: [String: URL?] = [:]   // stationID → resolved logo URL (nil = negative)
    private var lastRequest = Date.distantPast

    /// 275f379 (2): resolved chain results PERSIST — the 1-req/s politeness
    /// queue is paid ONCE per station, not once per session. Negatives carry
    /// a TTL (14 days) so a station that gains a logo is retried eventually.
    private static let persistKey = "radioLogoChainResults"
    private static let negativeTTL: TimeInterval = 14 * 24 * 3600
    private var persistedLoaded = false
    /// Stations whose chain FAILED in this session. Not persisted — a failed
    /// run says nothing about the station (95c5c16) — but the diagnosis needs
    /// it, because a failure and an unfinished run both leave the store empty.
    private(set) var failedThisSession: Set<String> = []

    /// 95c5c16: storage generation. The negatives written before the
    /// error/no-hit distinction existed are WRONG — a single disturbed
    /// phase (the RB outage on 03.08.) booked "no logo" for every station
    /// rendered during it, for 14 days. Bumping this discards the old
    /// NEGATIVES once on first launch; positives are kept (they were never
    /// in doubt).
    private static let storageVersionKey = "radioLogoChainVersion"
    /// v3 (cb8bac1): the width change 400→800 shipped WITHOUT a bump — and
    /// positives are kept on migration, so devices held width=400 URLs whose
    /// render the gate rejects (400×46 for wide wordmarks): every surface
    /// fell back to the mush favicon for 14 days. v3 HEALS the positives.
    ///
    /// v4 (b9de792): the SIBLING stage joined the chain on 21.08. — and a
    /// stored no-hit from the day BEFORE kept answering for 14 days, so
    /// "bigFM Deutsch Rap" showed initials although the family favicon the
    /// new stage rescues had been measured all along. A stored "no" is only
    /// valid for the chain that produced it; when the chain GAINS a stage,
    /// the old negatives must re-try. v4 drops negatives once (positives
    /// stay — a hit is a hit under any chain).
    ///
    /// v5 (e0a0788): the audit caught the runtime P154 stage booking FOREIGN
    /// marks (Life Radio → the LIFE magazine logo, the Reshet networks →
    /// Reset Media) — and a positive never expires. v5 drops exactly the
    /// MEASURED foreign files once; every other positive stays untouched.
    private static let storageVersion = 5

    /// The measured foreign marks of the audit run — the v5 drop list. Named
    /// files, not a heuristic: only what was seen wrong goes.
    nonisolated static let knownForeignMarks: Set<String> = [
        "LIFE magazine logo.svg",
        "Reset Media.svg",
    ]
    /// Testable mirror of the constant above.
    nonisolated static var currentStorageVersion: Int { storageVersion }

    /// The one Commons render width — the URL is built at READ time from the
    /// persisted FILE NAME, so the next width change needs no migration.
    nonisolated static let commonsWidth = 800

    /// The rule the poisoning broke, as a pure decision (95c5c16): a run that
    /// FAILED says nothing about the station and must not be written down —
    /// neither as a negative nor at all. Only a clean run may be booked.
    nonisolated static func mayPersist(outcomeFailed: Bool, foundURL: URL?) -> Bool {
        if outcomeFailed { return false }
        _ = foundURL   // a clean run is bookable either way (hit or no-hit)
        return true
    }

    /// One-shot migration of the poisoned generation — drops NEGATIVES only
    /// and returns how many went. Pure over the given defaults so the zaun
    /// test can drive it without touching the actor's state.
    @discardableResult
    nonisolated static func migratePersisted(defaults: UserDefaults, storedVersion: Int) -> Int {
        guard storedVersion < storageVersion else { return 0 }
        guard let data = defaults.data(forKey: persistKey),
              var stored = try? JSONDecoder().decode([String: Stored].self, from: data) else {
            defaults.set(storageVersion, forKey: storageVersionKey)
            return 0
        }
        var changed = 0
        // v1 → v2: the poisoned negatives go (error/no-hit was missing).
        // v3 → v4: negatives predate the SIBLING stage — same drop, new
        // reason (a no from a shorter chain must not outlive the chain).
        if storedVersion < 2 || storedVersion == 3 {
            let kept = stored.filter { $0.value.url != nil || $0.value.commonsFile != nil }
            changed += stored.count - kept.count
            stored = kept
        }
        // v2 → v3: HEAL the positives — a persisted Commons URL carries the
        // width it was written with; the file name is extracted so the URL
        // is built fresh at every read from the current constant.
        if storedVersion < 3 {
            for (id, entry) in stored {
                guard entry.commonsFile == nil,
                      let file = commonsFileName(fromStoredURL: entry.url) else { continue }
                stored[id] = Stored(url: nil, resolvedAt: entry.resolvedAt, commonsFile: file)
                changed += 1
            }
        }
        // v4 → v5: the measured foreign marks go — targeted, never a sweep.
        if storedVersion < 5 {
            let kept = stored.filter { entry in
                guard let file = entry.value.commonsFile
                    ?? commonsFileName(fromStoredURL: entry.value.url) else { return true }
                return !knownForeignMarks.contains(file)
            }
            changed += stored.count - kept.count
            stored = kept
        }
        if let encoded = try? JSONEncoder().encode(stored) {
            defaults.set(encoded, forKey: persistKey)
        }
        defaults.set(storageVersion, forKey: storageVersionKey)
        return changed
    }

    /// The file name inside a persisted Commons FilePath URL — nil for touch
    /// icons and anything else (those entries stay as they are).
    /// 383a3e8 family stage of the TABLE: an exact entry first; else the
    /// longest curated name that starts the folded name at a word boundary
    /// ("bigFM NRW" carries the bigFM mark). The audit measured 12 of 122
    /// initial-showing core stations covered by exactly this rule and 0
    /// false heads. An OWN entry always wins (DLF-Kultur guard: order, not
    /// luck) — and truncated catalog heads ("…") never match a prefix.
    nonisolated static func curatedFile(forName name: String) -> String? {
        if let file = RadioLogoData.commonsFile(forName: name) { return file }
        let lowered = name.lowercased()
        var best: (key: String, file: String)?
        for (key, file) in RadioLogoData.commonsFiles where key.count >= 4 {
            let head = key.lowercased()
            guard lowered.count > head.count, lowered.hasPrefix(head) else { continue }
            let next = lowered[lowered.index(lowered.startIndex, offsetBy: head.count)]
            guard !next.isLetter, !next.isNumber else { continue }
            if best == nil || key.count > best!.key.count { best = (key, file) }
        }
        return best?.file
    }

    /// What the chain has STORED per station — for the diagnosis surface, which
    /// must read the state without re-running anything.
    ///
    /// `resolvedAt` is part of the answer, not decoration: a result stored
    /// weeks ago says only that the station was resolved SOMETIME, which is a
    /// different claim from "the display resolved it just now". Without the age
    /// the report cannot tell a fresh success from an old one, and a diagnosis
    /// that cannot separate those answers the wrong question.
    nonisolated static func storedOutcomes(defaults: UserDefaults = .standard)
        -> [String: (hasLogo: Bool, attempted: Bool, resolvedAt: Double)] {
        guard let data = defaults.data(forKey: persistKey),
              let stored = try? JSONDecoder().decode([String: Stored].self, from: data)
        else { return [:] }
        return stored.mapValues { (hasLogo: $0.url != nil || $0.commonsFile != nil,
                                   attempted: true,
                                   resolvedAt: $0.resolvedAt) }
    }

    /// The URL a stored entry answers with today — for the diagnosis, which has
    /// to report what the tile ACTUALLY tries to load, not what was resolved.
    nonisolated static func storedURLs(defaults: UserDefaults = .standard) -> [String: URL] {
        guard let data = defaults.data(forKey: persistKey),
              let stored = try? JSONDecoder().decode([String: Stored].self, from: data)
        else { return [:] }
        return stored.compactMapValues { effectiveURL($0) }
    }

    nonisolated static func commonsFileName(fromStoredURL raw: String?) -> String? {
        guard let raw, raw.contains("commons.wikimedia.org"),
              let components = URLComponents(string: raw),
              let range = components.path.range(of: "Special:FilePath/") else { return nil }
        let file = String(components.path[range.upperBound...])
        return file.isEmpty ? nil : file
    }

    nonisolated fileprivate struct Stored: Codable {
        var url: String?          // nil = negative hit (touch icons keep a URL)
        var resolvedAt: Double    // epoch seconds
        /// Commons results persist the FILE NAME, never the finished URL —
        /// the width is applied at read time from the current constant.
        var commonsFile: String?
        /// 🔴 Punkt 6: the GATE the verdict was made under. A stored "no"
        /// is only valid for the thresholds that produced it — when they
        /// change, the no must be re-tried. Same class as the baked-in
        /// width (v3), one level up: for JUDGEMENTS instead of URLs.
        var gate: String?
    }

    /// The current gate signature. Deliberately DERIVED from the thresholds
    /// instead of a hand-counted version: nobody has to remember to bump it
    /// — that is exactly the trap the 400→800 width fell into (cb8bac1).
    nonisolated static var gateSignature: String {
        "\(RadioFaviconGate.minSide)-\(RadioFaviconGate.touchIconMinSide)"
    }

    /// The URL an entry answers TODAY — file-based entries render at the
    /// current width, legacy/touch entries keep their stored URL.
    nonisolated fileprivate static func effectiveURL(_ entry: Stored) -> URL? {
        if let file = entry.commonsFile {
            return ArtistPortraitLookup.commonsThumbURL(fileName: file, width: commonsWidth)
        }
        return entry.url.flatMap(URL.init(string:))
    }

    private func loadPersistedIfNeeded() {
        guard !persistedLoaded else { return }
        persistedLoaded = true
        let defaults = UserDefaults.standard
        // 95c5c16 self-healing: the negatives written before the error/no-hit
        // distinction existed are wrong — drop that generation ONCE.
        let dropped = Self.migratePersisted(
            defaults: defaults, storedVersion: defaults.integer(forKey: Self.storageVersionKey))
        if dropped > 0 {
            Logger.library.notice("RADIO logo cache: dropped \(dropped) stale negative(s) — error/no-hit distinction was missing")
        }
        guard let data = defaults.data(forKey: Self.persistKey),
              let stored = try? JSONDecoder().decode([String: Stored].self, from: data) else { return }
        let now = Date().timeIntervalSince1970
        var staleGate = 0
        for (id, entry) in stored {
            let isNegative = entry.url == nil && entry.commonsFile == nil
            if isNegative, now - entry.resolvedAt > Self.negativeTTL { continue }
            // A NO made under different thresholds is re-tried; a YES stays
            // (a positive does not become wrong because the gate loosened).
            if isNegative, entry.gate != Self.gateSignature {
                staleGate += 1
                continue
            }
            cache[id] = Self.effectiveURL(entry)
        }
        if staleGate > 0 {
            Logger.library.notice("RADIO logo cache: \(staleGate) negative(s) re-opened — gate changed to \(Self.gateSignature, privacy: .public)")
        }
    }

    // R25/R32: a stored positive never expires — so a result whose picture
    // stopped serving (frontend version paths) or whose size today's gates
    // would refuse (the 57-px stock) showed letters forever. The DISPLAY is
    // the witness: it re-opens the decision, it never books a negative.
    private static let displayFailsKey = "radioLogoDisplayFails"
    private static let displayFailsBeforeDiscard = 2

    /// Drops the stored result so the chain re-decides — deliberately NOT a
    /// stored no-hit (Negativ-Cache-Regel: clearing re-opens the question).
    /// The persist halves are nonisolated statics (UserDefaults is not
    /// Sendable across the actor hop); the actor wrappers below add the
    /// session-cache half.
    @discardableResult
    nonisolated static func discardStoredEntry(stationID: String,
                                               defaults: UserDefaults = .standard) -> Bool {
        var stored = (defaults.data(forKey: persistKey))
            .flatMap { try? JSONDecoder().decode([String: Stored].self, from: $0) } ?? [:]
        guard stored.removeValue(forKey: stationID) != nil else { return false }
        if let data = try? JSONEncoder().encode(stored) {
            defaults.set(data, forKey: persistKey)
        }
        clearDisplayStrikes(stationID: stationID, defaults: defaults)
        return true
    }

    /// A load failure WITH network up. Counted persistently (one failure per
    /// session is the 0nlineradio shape) — the second discards. A single
    /// failure is never a verdict (95c5c16), so nothing happens on the first.
    /// Returns true when the entry was discarded.
    nonisolated static func registerDisplayFailure(stationID: String,
                                                   defaults: UserDefaults = .standard) -> Bool {
        var fails = defaults.dictionary(forKey: displayFailsKey) as? [String: Int] ?? [:]
        let count = (fails[stationID] ?? 0) + 1
        if count >= displayFailsBeforeDiscard {
            fails.removeValue(forKey: stationID)
            defaults.set(fails, forKey: displayFailsKey)
            return discardStoredEntry(stationID: stationID, defaults: defaults)
        }
        fails[stationID] = count
        defaults.set(fails, forKey: displayFailsKey)
        return false
    }

    /// A successful display load clears the strike — two failures must be
    /// consecutive, or flaky transport would erode healthy results.
    nonisolated static func clearDisplayStrikes(stationID: String,
                                                defaults: UserDefaults = .standard) {
        var fails = defaults.dictionary(forKey: displayFailsKey) as? [String: Int] ?? [:]
        guard fails.removeValue(forKey: stationID) != nil else { return }
        defaults.set(fails, forKey: displayFailsKey)
    }

    /// Actor half: also clears the session cache so the chain runs again.
    func discardStored(stationID: String, reason: String) {
        cache.removeValue(forKey: stationID)
        givenUpThisSession.remove(stationID)
        guard Self.discardStoredEntry(stationID: stationID) else { return }
        Logger.library.notice("RADIO stored result discarded (\(reason, privacy: .public)): \(stationID, privacy: .public) — chain re-decides")
    }

    func noteDisplayFailure(stationID: String) {
        if Self.registerDisplayFailure(stationID: stationID) {
            cache.removeValue(forKey: stationID)
            givenUpThisSession.remove(stationID)
            Logger.library.notice("RADIO stored result discarded (did not load twice): \(stationID, privacy: .public) — chain re-decides")
        }
    }

    private func persistResult(stationID: String, url: URL?, commonsFile: String?) {
        var stored = (UserDefaults.standard.data(forKey: Self.persistKey))
            .flatMap { try? JSONDecoder().decode([String: Stored].self, from: $0) } ?? [:]
        // Commons: the file name is the durable fact, the URL only today's
        // rendering of it. Touch icons have no file and keep their URL.
        stored[stationID] = Stored(url: commonsFile == nil ? url?.absoluteString : nil,
                                   resolvedAt: Date().timeIntervalSince1970,
                                   commonsFile: commonsFile,
                                   gate: Self.gateSignature)
        if let data = try? JSONEncoder().encode(stored) {
            UserDefaults.standard.set(data, forKey: Self.persistKey)
        }
    }

    /// bc11ed5: the 1 s spacing was inherited from the MusicBrainz manners,
    /// but this chain talks to Wikidata/Commons and station homepages — none
    /// of which asks for one request per second. Measured effect of the old
    /// value: with a screen full of tiles the fourth station's turn came
    /// minutes late, by which time SwiftUI had cancelled its `.task`. Still
    /// polite, just not artificially slow.
    private static let politeSpacing: TimeInterval = 0.34
    /// Testable mirror of the spacing above.
    nonisolated static var politeSpacingSeconds: TimeInterval { politeSpacing }

    private func politeDelay() async {
        let elapsed = Date().timeIntervalSince(lastRequest)
        if elapsed < Self.politeSpacing {
            try? await Task.sleep(nanoseconds: UInt64((Self.politeSpacing - elapsed) * 1_000_000_000))
        }
        lastRequest = Date()
    }

    /// 95c5c16: a fetch has THREE outcomes, and collapsing them into `nil`
    /// is what poisoned the cache — a transport error looked exactly like
    /// "this station has no logo" and got written down for 14 days.
    private enum FetchResult {
        case data(Data)
        /// Reached the server, but nothing usable (non-2xx, empty body).
        case empty
        /// Never got an answer — says NOTHING about the station.
        case failed
    }

    private func fetch(_ url: URL) async -> FetchResult {
        await politeDelay()
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.setValue(LibriVoxClient.userAgent, forHTTPHeaderField: "User-Agent")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                return http.statusCode >= 500 ? .failed : .empty
            }
            return data.isEmpty ? .empty : .data(data)
        } catch {
            return .failed
        }
    }

    /// The resolved logo URL for a station, chain order fixed; every outcome
    /// (incl. nil) is session-cached.
    /// bc11ed5: resolving must SURVIVE the caller. A tile's `.task` is
    /// cancelled the moment it scrolls off screen — with the queue in front
    /// of it, the work was thrown away just before it finished, over and
    /// over, and nothing was ever written down. The chain therefore runs in
    /// its own task; the caller may go, the result stays.
    private var inFlight: [String: Task<URL?, Never>] = [:]

    /// Resolve the logos of a whole ROW, in the background, as soon as its data
    /// is in hand — instead of waiting for each tile to become visible.
    ///
    /// This is the fix for "letters until I play a station once": the chain was
    /// only ever started by a VISIBLE tile, so a station one never looked at
    /// long enough never got a stored result, and the next visit started from
    /// zero again. The row has the stations before the tiles exist; kicking the
    /// resolution off there means the result is persisted regardless of scroll
    /// position, and the second visit is instant.
    ///
    /// Deliberately fire-and-forget: nothing awaits it, the polite spacing
    /// still applies, and a station already resolved returns from the cache
    /// without a request.
    func warm(_ stations: [(id: String, name: String, homepage: String?)]) {
        for station in stations {
            guard cache[station.id] == nil, inFlight[station.id] == nil,
                  !givenUpThisSession.contains(station.id) else { continue }
            Task { _ = await logoURL(stationID: station.id, name: station.name,
                                     homepage: station.homepage) }
        }
    }

    /// The session's live answer for the diagnosis (4fe882b): a station with
    /// nothing stored is in one of THREE states, and they are different
    /// causes — still waiting for its turn, tried-and-transport-failed, or
    /// given up for the session. Stored state cannot tell them apart.
    func sessionState() -> (waiting: Set<String>, failed: Set<String>, gaveUp: Set<String>) {
        (waiting: Set(inFlight.keys), failed: failedThisSession, gaveUp: givenUpThisSession)
    }

    /// 383a3e8: the audit's window into the chain — runs the REAL resolve
    /// (same stages, same guards) but books NOTHING: no cache, no persist,
    /// no session sets. A measurement may not change what it measures.
    func auditChain(name: String, homepage: String?) async -> String {
        let folded = RadioMapping.displayName(name)
        switch await resolve(name: folded, homepage: homepage) {
        case .hit(let url, let commonsFile, let stage):
            return "TREFFER stufe=\(stage) datei=\(commonsFile ?? url.absoluteString)"
        case .noHit:
            return "KEIN TREFFER (alle Stufen sauber durchlaufen)"
        case .failed(let stage):
            return "FEHLSCHLAG stufe=\(stage)"
        }
    }

    /// Stations whose chain failed REPEATEDLY in this session. A failed run is
    /// never booked (95c5c16) — which is right for a network hiccup and wrong
    /// for a homepage that is simply gone: without a stop those stations retry
    /// on every render, and because the queue is serialised they eat the turns
    /// of stations that WOULD resolve. Session-scoped, so the next start tries
    /// again — a permanent verdict still may not be written down.
    private var failureCount: [String: Int] = [:]
    private var givenUpThisSession: Set<String> = []
    private static let failuresBeforeGivingUp = 2

    func logoURL(stationID: String, name: String, homepage: String?) async -> URL? {
        loadPersistedIfNeeded()
        // 51ea272 (Kandidat 3 aus 9c7cad0, am Geraet gemessen): the user'
        // Katalog-Eintrag heisst "Deutschlandfunk | DLF | AAC 192k" — the raw
        // name misses the table and falls through to the chain, which serves
        // the wordmark. The FOLD comes first (the same displayName cut the
        // rows already use), so a table entry covers every name variant of
        // its station instead of exactly one.
        let name = RadioMapping.displayName(name)
        // 9c7cad0: the curated table comes BEFORE every stored result.
        //
        // Measured on the user's device: the DLF card kept the wordmark on a
        // build whose table carries the 1:1 mark — and clearing the IMAGE
        // cache brought the wordmark back, freshly fetched. The reason was
        // this method's order: a persisted positive never expires, so the
        // chain (whose stage 0 asks the table) never ran again for a station
        // that resolved once. Every table update reached only stations
        // without a stored result.
        //
        // The table is local data — one dictionary lookup, no network, no
        // budget. Asking it FIRST costs nothing and makes every future table
        // update reach every surface immediately, with no migration and no
        // stored generation to invalidate.
        if let file = Self.curatedFile(forName: name),
           let thumb = ArtistPortraitLookup.commonsThumbURL(fileName: file,
                                                            width: Self.commonsWidth) {
            if cache[stationID] != .some(thumb) {
                Logger.library.notice("RADIO logo source=curated-table for \(name, privacy: .public)")
            }
            cache[stationID] = thumb
            return thumb
        }
        if let cached = cache[stationID] { return cached }
        if let running = inFlight[stationID] { return await running.value }
        guard AppStorageKeys.radioLogoChainEnabledValue else { return nil }
        // Stations that failed twice this session are skipped — they would
        // only take turns away from the ones that can still resolve.
        guard !givenUpThisSession.contains(stationID) else { return nil }
        // 95c5c16 (3): offline ⇒ do not run the chain at all. No result, no
        // booking — otherwise a flight-mode session burns every station in.
        guard await NetworkMonitor.shared.isConnected else { return nil }
        let task = Task { [weak self] () -> URL? in
            guard let self else { return nil }
            return await self.runChain(stationID: stationID, name: name, homepage: homepage)
        }
        inFlight[stationID] = task
        let result = await task.value
        inFlight[stationID] = nil
        return result
    }

    /// The chain proper — deliberately NOT cancellable from the outside.
    private func runChain(stationID: String, name: String, homepage: String?) async -> URL? {
        let outcome = await resolve(name: name, homepage: homepage)
        switch outcome {
        case .hit(let url, let commonsFile, _):
            cache[stationID] = url
            persistResult(stationID: stationID, url: url, commonsFile: commonsFile)
            return url
        case .noHit:
            // Every stage ran cleanly and found nothing — THIS may be booked.
            cache[stationID] = URL?.none
            persistResult(stationID: stationID, url: nil, commonsFile: nil)
            Logger.library.notice("RADIO logo chain: no-hit for \(name, privacy: .public)")
            return nil
        case .failed(let stage):
            // Nothing is stored — not even in the session cache, so the next
            // appearance is free to try again. But the DIAGNOSIS has to be able
            // to tell this apart from "never got its turn": both look like
            // "nothing stored", and they are different causes. Kept for the
            // session only, exactly like the retry it allows.
            failedThisSession.insert(stationID)
            failureCount[stationID, default: 0] += 1
            if failureCount[stationID, default: 0] >= Self.failuresBeforeGivingUp {
                givenUpThisSession.insert(stationID)
            }
            Logger.library.notice("RADIO logo chain: fetch-failed stage=\(stage, privacy: .public) for \(name, privacy: .public)")
            return nil
        }
    }

    /// The chain's outcome, kept apart on purpose (95c5c16).
    private enum ChainOutcome {
        // 383a3e8: every hit NAMES its stage — the audit and the diagnosis
        // must be able to say WHICH rung answered, not just that one did.
        case hit(URL, commonsFile: String?, stage: String)
        case noHit
        case failed(String)
    }

    /// 95c5c16: the chain now REPORTS a failure instead of swallowing it.
    /// Rule: a `.noHit` may only be returned when every stage that ran
    /// answered cleanly; the first transport failure aborts with `.failed`,
    /// so nothing gets written down on the strength of a broken network.
    private func resolve(name: String, homepage: String?) async -> ChainOutcome {
        // 🔴 e32454e: the GENERATED data first — for the core stations the
        // answer is already known (P154 plus the Commons file search, run
        // tool-side). This spares the device the whole chain for exactly the
        // stations everyone sees; the runtime chain below stays the fallback
        // for the long tail. Only the FILE NAME is stored, the width is
        // applied at read time (cb8bac1).
        if let file = Self.curatedFile(forName: name),
           let thumb = ArtistPortraitLookup.commonsThumbURL(fileName: file,
                                                            width: Self.commonsWidth) {
            return .hit(thumb, commonsFile: file, stage: "tabelle")
        }
        // Stage 1: Wikidata P154 — term variants (full name de/en, brand
        // stem) because the de full-name search missed real entries
        // (90s90s-Diagnose); the conservative fold-match guards each hit.
        for term in RadioLogoLookup.searchTerms(for: name) {
            for language in ["de", "en"] {
                guard let searchURL = RadioLogoLookup.wikidataSearchURL(name: term, language: language)
                else { continue }
                let search = await fetch(searchURL)
                if case .failed = search { return .failed("wikidata-search") }
                guard case .data(let searchData) = search,
                      let match = RadioLogoLookup.matchedEntity(fromSearchData: searchData,
                                                                stationName: name)
                else { continue }
                let entity = match.id
                guard let entityURL = ArtistPortraitLookup.wikidataEntityURL(entity) else { break }
                let entityResult = await fetch(entityURL)
                if case .failed = entityResult { return .failed("wikidata-entity") }
                if case .data(let entityData) = entityResult,
                   let fileName = RadioLogoLookup.p154FileName(fromEntityData: entityData, entity: entity),
                   // e0a0788: this stage PERSISTS, so it carries the
                   // generator's name guard — a file answering for a
                   // different house must fall through, not stick forever.
                   RadioLogoLookup.fileCarriesLabel(fileName, label: match.label),
                   // width 800, not the portrait default of 400: station
                   // logos are often WIDE wordmarks (DLF Kultur measures
                   // 960×110 — at 400 the render's short side lands at ~46 px
                   // and the quality gate would reject the very source the
                   // decision made primary; at 800 it clears 64 px with room).
                   let thumb = ArtistPortraitLookup.commonsThumbURL(fileName: fileName, width: Self.commonsWidth) {
                    return .hit(thumb, commonsFile: fileName, stage: "wikidata")
                }
                break   // entity found but no P154 → deeper terms won't help this language pair
            }
        }
        // Stage 2: homepage apple-touch-icon (first-party).
        // R41: the funnel raises the catalog's homepage to https — an http
        // request would be dropped by ATS before it leaves the device (the
        // stage was dead for half the German catalog, measured).
        guard let pageURL = RadioLogoLookup.httpsPageURL(homepage) else { return .noHit }
        let page = await fetch(pageURL)
        if case .failed = page { return .failed("homepage") }
        if case .data(let data) = page, let html = String(data: data, encoding: .utf8),
           let icon = RadioLogoLookup.extractTouchIcon(html: html, baseURL: pageURL) {
            return .hit(icon, commonsFile: nil, stage: "homepage")
        }
        // Stage 3 (4e1688d): the SIBLING entries of the same station. The
        // catalog carries a station several times, and the entry with the most
        // votes is not always the one with a picture — bigFM Deutschland has
        // 497 votes and an empty favicon while its 88-vote sibling carries a
        // 600×600 image. Measured: this rescues 24 % of the favicon-less
        // stations in the DE/CH/AT top 200.
        //
        // It sits BEHIND Wikidata and the homepage on purpose: those are
        // curated or first-party, while a sibling's favicon was chosen by a
        // stranger for a DIFFERENT entry. And it sits AHEAD of the convention
        // URL, because it is a real image someone published rather than a
        // guess at a path.
        if let mirror = RadioBrowserClient.mirrors.first {
            // R24: two search terms — the declared stem first, then the
            // family stem for members without a separator ("bigFM Deutsch
            // Rap" → "bigFM" finds the head whose sibling carries the real
            // mark). Acceptance is identical for both (domain + kinship).
            var terms = [RadioLogoLookup.brandStem(of: name)]
            if let family = RadioLogoLookup.familyStem(of: name),
               !terms.contains(family) { terms.append(family) }
            for term in terms {
                guard let searchURL = RadioLogoLookup.siblingSearchURL(name: term,
                                                                       mirror: mirror)
                else { continue }
                let siblings = await fetch(searchURL)
                if case .failed = siblings { return .failed("siblings") }
                if case .data(let data) = siblings,
                   let favicon = RadioLogoLookup.siblingFaviconURL(fromSearchData: data,
                                                                   stationName: name,
                                                                   homepage: homepage) {
                    // Verified before it counts — same rule as the convention
                    // URL: a stored positive never expires, so a dead link
                    // would show letters forever without ever asking again.
                    if case .data = await fetch(favicon) {
                        Logger.library.notice("RADIO logo chain: sibling favicon for \(name, privacy: .public)")
                        return .hit(favicon, commonsFile: nil, stage: "geschwister")
                    }
                }
            }
        }
        // The convention URL is a GUESS (`https://<host>/apple-touch-icon.png`),
        // and a guess must not be booked as a finding: a station whose site has
        // no such file got a stored "logo" that answers 404 forever, and a
        // positive never expires — so the tile showed letters and never asked
        // again. It is checked before it counts.
        if let convention = RadioLogoLookup.conventionTouchIconURL(homepage: pageURL) {
            switch await fetch(convention) {
            case .data:
                return .hit(convention, commonsFile: nil, stage: "konvention")
            case .empty:
                // The host answered, and there is nothing there. A clean
                // no-hit — bookable, and it stops the guess being retried.
                return .noHit
            case .failed:
                // No answer says nothing about the station (95c5c16): not a
                // no-hit either, so nothing is written down.
                return .failed("convention-icon")
            }
        }
        return .noHit
    }
}
