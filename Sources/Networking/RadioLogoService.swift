// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation
import UIKit
import OSLog

/// The radio-logo fallback chain BEHIND the gated favicon.
/// Wikidata P154 first, then the homepage apple-touch-icon, then nothing
/// (placeholder). Reuses the portrait chain's manners: identifying UA,
/// ~1 req/s politeness, session cache INCLUDING negatives (a no-hit never
/// re-asks), opt-out on the network-services page (`radioLogoChainEnabled`).
/// Images ride the shared ImageCache (persistent).
actor RadioLogoService {
    static let shared = RadioLogoService()

    /// The wire the chain fetches over and the store its results live in.
    /// Both are handed in so a witness can run the WHOLE chain against a
    /// fake host and read the store afterwards; the app passes nothing.
    /// The store comes as a suite name, opened here: a `UserDefaults`
    /// cannot be sent into an actor, and the suite is the same object for
    /// whoever opens it.
    typealias Wire = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse?)
    private let wire: Wire
    private let defaults: UserDefaults

    init(wire: @escaping Wire = { try await HTTP.data(for: $0, lane: .stream) },
         suite: String? = nil) {
        self.wire = wire
        self.defaults = suite.flatMap { UserDefaults(suiteName: $0) } ?? AppStorageKeys.store
    }

    private var cache: [String: URL?] = [:]   // stationID → resolved logo URL (nil = negative)

    /// Resolved chain results PERSIST, in the door's one directory under
    /// `radio|<station id>`. The chain runs ONCE per station, not once per
    /// session. Negatives carry a span (14 days) so a station
    /// that gains a logo is retried eventually; a found logo never expires.
    private static let memoPrefix = "radio|"
    private static let commonsValuePrefix = "commons:"
    private static let negativeTTL: TimeInterval = 14 * 24 * 3600
    private var persistedLoaded = false
    /// Stations whose chain FAILED in this session. Not persisted. A failed
    /// run says nothing about the station. But the diagnosis needs
    /// it, because a failure and an unfinished run both leave the store empty.
    private(set) var failedThisSession: Set<String> = []

    /// The one Commons render width. The URL is built at READ time from the
    /// persisted FILE NAME, so the next width change needs no migration.
    nonisolated static let commonsWidth = 800

    /// The rule the poisoning broke, as a pure decision: a run that
    /// FAILED says nothing about the station and must not be written down.
    /// Neither as a negative nor at all. Only a clean run may be booked,
    /// with its hit or as a clean no-hit. The chain books through this
    /// answer and nothing else.
    nonisolated static func booking(_ outcome: ChainOutcome) -> Booking {
        switch outcome {
        case .hit(let url, let commonsFile, _): return .store(url, commonsFile: commonsFile)
        case .noHit: return .store(nil, commonsFile: nil)
        case .failed(let stage): return .skip(stage: stage)
        }
    }

    /// What a finished run writes down: a hit or a clean no-hit, or nothing.
    nonisolated enum Booking: Equatable, Sendable {
        case store(URL?, commonsFile: String?)
        case skip(stage: String)
    }

    /// Family stage of the TABLE: an exact entry first; else the longest
    /// curated name that starts the folded name at a word boundary ("bigFM
    /// NRW" carries the bigFM mark). Measured: 12 of 122 initial-showing core
    /// stations covered by exactly this rule, 0 false heads. An OWN entry
    /// always wins (order, not
    /// luck). And truncated catalog heads ("…") never match a prefix.
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

    /// What the chain has STORED per station. For the diagnosis surface, which
    /// must read the state without re-running anything.
    ///
    /// `resolvedAt` is part of the answer, not decoration: a result stored
    /// weeks ago says only that the station was resolved SOMETIME, which is a
    /// different claim from "the display resolved it just now". Without the age
    /// the report cannot tell a fresh success from an old one, and a diagnosis
    /// that cannot separate those answers the wrong question.
    nonisolated static func storedOutcomes(defaults: UserDefaults = AppStorageKeys.store)
        -> [String: (hasLogo: Bool, attempted: Bool, resolvedAt: Double)] {
        Artwork.Memo.entries(prefix: memoPrefix, defaults: defaults)
            .mapValues { (hasLogo: $0.value != nil, attempted: true, resolvedAt: $0.resolvedAt) }
    }

    /// The URL a stored entry answers with today. For the diagnosis, which has
    /// to report what the tile ACTUALLY tries to load, not what was resolved.
    nonisolated static func storedURLs(defaults: UserDefaults = AppStorageKeys.store) -> [String: URL] {
        Artwork.Memo.entries(prefix: memoPrefix, defaults: defaults)
            .compactMapValues { storedURL($0.value) }
    }

    /// The current gate signature. Deliberately DERIVED from the thresholds
    /// instead of a hand-counted version: nobody has to remember to bump it.
    /// That is exactly the trap the 400→800 width fell into.
    nonisolated static var gateSignature: String {
        "\(RadioFaviconGate.minSide)-\(RadioFaviconGate.touchIconMinSide)"
    }

    /// The URL a stored value answers TODAY. A Commons file renders at the
    /// current width, a touch icon keeps its stored address.
    nonisolated static func storedURL(_ value: String?) -> URL? {
        guard let value else { return nil }
        if value.hasPrefix(commonsValuePrefix) {
            return ArtistPortraitLookup.commonsThumbURL(
                fileName: String(value.dropFirst(commonsValuePrefix.count)), width: commonsWidth)
        }
        return URL(string: value)
    }

    private func loadPersistedIfNeeded() {
        guard !persistedLoaded else { return }
        persistedLoaded = true
        // The directory applies the span and the gate rule: an expired no
        // and a no made under other thresholds are open again, a yes stays.
        for (id, answer) in Artwork.Memo.answers(prefix: Self.memoPrefix, under: Self.gateSignature,
                                                 defaults: defaults) {
            switch answer {
            case .found(let value): cache[id] = Self.storedURL(value)
            case .missing: cache[id] = URL?.none
            }
        }
    }

    // A stored positive never expires. So a result whose picture
    // stopped serving (frontend version paths) or whose size today's gates
    // would refuse (the 57-px stock) showed letters forever. The DISPLAY is
    // the witness: it re-opens the decision, it never books a negative.
    private static let displayFailsKey = "radioLogoDisplayFails"
    private static let displayFailsBeforeDiscard = 2

    /// Drops the stored result so the chain re-decides. Deliberately NOT a
    /// stored no-hit (Negativ-Cache-Regel: clearing re-opens the question).
    /// The persist halves are nonisolated statics (UserDefaults is not
    /// Sendable across the actor hop); the actor wrappers below add the
    /// session-cache half.
    @discardableResult
    nonisolated static func discardStoredEntry(stationID: String,
                                               defaults: UserDefaults = AppStorageKeys.store) -> Bool {
        guard Artwork.Memo.forget(memoPrefix + stationID, defaults: defaults) else { return false }
        clearDisplayStrikes(stationID: stationID, defaults: defaults)
        return true
    }

    /// A load failure WITH network up. Counted persistently (one failure per
    /// session is the 0nlineradio shape). The second discards. A single
    /// failure is never a verdict, so nothing happens on the first.
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

    /// A successful display load clears the strike. Two failures must be
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
        // Commons: the file name is the durable fact, the URL only today's
        // rendering of it. Touch icons have no file and keep their URL. A
        // found logo never expires; a clean no counts 14 days, under the
        // gate it was made under.
        let value = commonsFile.map { Self.commonsValuePrefix + $0 } ?? url?.absoluteString
        let now = Date().timeIntervalSince1970
        Artwork.Memo.remember(Self.memoPrefix + stationID, value: value,
                              until: value == nil ? now + Self.negativeTTL : nil,
                              under: Self.gateSignature, now: now, defaults: defaults)
    }

    /// A fetch has THREE outcomes, and collapsing them into `nil`
    /// is what poisoned the cache. A transport error looked exactly like
    /// "this station has no logo" and got written down for 14 days.
    enum FetchResult: Equatable {
        case data(Data)
        /// Reached the server, and there is nothing there: an empty body,
        /// or a status that says "not here" (404, 410).
        case empty
        /// No answer that says anything about the station: transport, a
        /// server error, or a REFUSAL (401, 403, 429).
        case failed
    }

    /// Which of the outcomes a non-2xx status is. Only a real "not there"
    /// is a clean no; a refusal and a server error say nothing about the
    /// station and must never be booked. Before this rule everything below
    /// 500 counted as a clean no, so a throttled or blocking host took a
    /// station's logo away for the whole negative span. The stream lane
    /// has no retry ladder by design, so the meaning is final here.
    nonisolated static func fetchResult(forStatus status: Int) -> FetchResult {
        StatusMeaning.from(status: status).isAbsence ? .empty : .failed
    }

    private func fetch(_ url: URL) async -> FetchResult {
        // No spacing of its own: the host courtesy runs the Wikimedia hosts
        // one after the other and caps every other host.
        let request = URLRequest(url: url, timeoutInterval: 15)
        do {
            // The stream lane: no retry, a logo host that stalls gets one try.
            let (data, http) = try await wire(request)
            if let http, !(200...299).contains(http.statusCode) {
                return Self.fetchResult(forStatus: http.statusCode)
            }
            return data.isEmpty ? .empty : .data(data)
        } catch {
            return .failed
        }
    }

    /// The resolved logo URL for a station, chain order fixed; every outcome
    /// (incl. nil) is session-cached.
    /// Resolving must SURVIVE the caller. A tile's `.task` is
    /// cancelled the moment it scrolls off screen. With the queue in front
    /// of it, the work was thrown away just before it finished, over and
    /// over, and nothing was ever written down. The chain therefore runs in
    /// its own task; the caller may go, the result stays.
    private var inFlight: [String: Task<URL?, Never>] = [:]

    /// Resolve the logos of a whole ROW, in the background, as soon as its data
    /// is in hand. Instead of waiting for each tile to become visible.
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

    /// The session's live answer for the diagnosis: a station with
    /// nothing stored is in one of THREE states, and they are different
    /// causes. Still waiting for its turn, tried-and-transport-failed, or
    /// given up for the session. Stored state cannot tell them apart.
    func sessionState() -> (waiting: Set<String>, failed: Set<String>, gaveUp: Set<String>) {
        (waiting: Set(inFlight.keys), failed: failedThisSession, gaveUp: givenUpThisSession)
    }

    /// The audit's window into the chain. Runs the REAL resolve
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
    /// never booked. Which is right for a network hiccup and wrong
    /// for a homepage that is simply gone: without a stop those stations retry
    /// on every render, and because the queue is serialised they eat the turns
    /// of stations that WOULD resolve. Session-scoped, so the next start tries
    /// again. A permanent verdict still may not be written down.
    private var failureCount: [String: Int] = [:]
    private var givenUpThisSession: Set<String> = []
    private static let failuresBeforeGivingUp = 2

    func logoURL(stationID: String, name: String, homepage: String?) async -> URL? {
        loadPersistedIfNeeded()
        // Measured on the device: a catalog entry named
        // "Deutschlandfunk | DLF | AAC 192k". The raw
        // name misses the table and falls through to the chain, which serves
        // the wordmark. The FOLD comes first (the same displayName cut the
        // rows already use), so a table entry covers every name variant of
        // its station instead of exactly one.
        let name = RadioMapping.displayName(name)
        // The curated table comes BEFORE every stored result.
        //
        // Measured on the user's device: the DLF card kept the wordmark on a
        // build whose table carries the 1:1 mark. And clearing the IMAGE
        // cache brought the wordmark back, freshly fetched. The reason was
        // this method's order: a persisted positive never expires, so the
        // chain (whose stage 0 asks the table) never ran again for a station
        // that resolved once. Every table update reached only stations
        // without a stored result.
        //
        // The table is local data. One dictionary lookup, no network, no
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
        // Stations that failed twice this session are skipped. They would
        // only take turns away from the ones that can still resolve.
        guard !givenUpThisSession.contains(stationID) else { return nil }
        // Offline ⇒ do not run the chain at all. No result, no
        // booking. Otherwise a flight-mode session burns every station in.
        guard await Reachability.isConnected() else { return nil }
        // A tile stays a moment before the chain runs (`TileDwell`), in
        // the tile's own task: a tile that left starts no chain.
        guard await TileDwell.stood(TileDwell.lookup) else { return nil }
        let task = Task { [weak self] () -> URL? in
            guard let self else { return nil }
            return await self.runChain(stationID: stationID, name: name, homepage: homepage)
        }
        inFlight[stationID] = task
        let result = await task.value
        inFlight[stationID] = nil
        return result
    }

    /// The chain proper. Deliberately NOT cancellable from the outside.
    private func runChain(stationID: String, name: String, homepage: String?) async -> URL? {
        let outcome = await resolve(name: name, homepage: homepage)
        switch Self.booking(outcome) {
        case .store(let url, let commonsFile):
            // A hit, or every stage ran cleanly and found nothing. Both may be booked.
            cache[stationID] = url
            persistResult(stationID: stationID, url: url, commonsFile: commonsFile)
            if url == nil {
                Logger.library.notice("RADIO logo chain: no-hit for \(name, privacy: .public)")
            }
            return url
        case .skip(let stage):
            // Nothing is stored. Not even in the session cache, so the next
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

    /// The chain's outcome, kept apart on purpose.
    nonisolated enum ChainOutcome: Sendable {
        // Every hit NAMES its stage. The audit and the diagnosis
        // must be able to say WHICH rung answered, not just that one did.
        case hit(URL, commonsFile: String?, stage: String)
        case noHit
        case failed(String)
    }

    /// The usable icon the root page of the station's host declares, for a
    /// page that refused; nil when the page is the root itself, or the root
    /// gives no usable icon.
    private func rootIcon(of pageURL: URL) async -> ChainOutcome? {
        guard let rootURL = RadioLogoLookup.rootPageURL(of: pageURL),
              case .data(let data) = await fetch(rootURL),
              let html = String(data: data, encoding: .utf8),
              let icon = RadioLogoLookup.extractTouchIcon(html: html, baseURL: rootURL),
              case .data(let body) = await fetch(icon),
              RadioLogoLookup.usableLogo(body) else { return nil }
        return .hit(icon, commonsFile: nil, stage: "wurzel")
    }

    /// The chain now REPORTS a failure instead of swallowing it.
    /// Rule: a `.noHit` may only be returned when every stage that ran
    /// answered cleanly; the first transport failure aborts with `.failed`,
    /// so nothing gets written down on the strength of a broken network.
    private func resolve(name: String, homepage: String?) async -> ChainOutcome {
        // 🔴 The GENERATED data first. For the core stations the
        // answer is already known (P154 plus the Commons file search, run
        // tool-side). This spares the device the whole chain for exactly the
        // stations everyone sees; the runtime chain below stays the fallback
        // for the long tail. Only the FILE NAME is stored, the width is
        // applied at read time.
        if let file = Self.curatedFile(forName: name),
           let thumb = ArtistPortraitLookup.commonsThumbURL(fileName: file,
                                                            width: Self.commonsWidth) {
            // Booked only if the render actually serves. The table was
            // proven at generation time, but a Commons file can move or
            // stop rastering afterwards; an unusable render falls through
            // to the runtime chain instead of sticking as a dead positive.
            switch await fetch(thumb) {
            case .data(let body) where RadioLogoLookup.usableLogo(body):
                return .hit(thumb, commonsFile: file, stage: "tabelle")
            case .failed:
                return .failed("tabelle-render")
            default:
                break
            }
        }
        // Stage 1: Wikidata P154. Term variants (full name de/en, brand
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
                   // This stage PERSISTS, so it carries the
                   // generator's name guard. A file answering for a
                   // different house must fall through, not stick forever.
                   RadioLogoLookup.fileCarriesLabel(fileName, label: match.label),
                   // width 800, not the portrait default of 400: station
                   // logos are often WIDE wordmarks (DLF Kultur measures
                   // 960×110. At 400 the render's short side lands at ~46 px
                   // and the quality gate would reject the very source the
                   // decision made primary; at 800 it clears 64 px with room).
                   let thumb = ArtistPortraitLookup.commonsThumbURL(fileName: fileName, width: Self.commonsWidth) {
                    // The render must serve before it counts; single
                    // files fail MediaWiki's rasterisation while their
                    // siblings pass, and a booked dead render showed
                    // letters until the display had failed twice.
                    switch await fetch(thumb) {
                    case .data(let body) where RadioLogoLookup.usableLogo(body):
                        return .hit(thumb, commonsFile: fileName, stage: "wikidata")
                    case .failed:
                        return .failed("wikidata-render")
                    default:
                        break
                    }
                }
                break   // entity found but no P154 → deeper terms won't help this language pair
            }
        }
        // Stage 2: homepage apple-touch-icon (first-party).
        // The funnel raises the catalog's homepage to https. An http
        // request would be dropped by ATS before it leaves the device (the
        // stage was dead for half the German catalog, measured).
        guard let pageURL = RadioLogoLookup.httpsPageURL(homepage) else { return .noHit }
        let page = await fetch(pageURL)
        if case .failed = page {
            // A refusing page says nothing about the station, so nothing is
            // booked from here. The root of the same host often answers
            // where a deep page refuses, and its icon is the site's own mark.
            return await rootIcon(of: pageURL) ?? .failed("homepage")
        }
        if case .data(let data) = page, let html = String(data: data, encoding: .utf8),
           let icon = RadioLogoLookup.extractTouchIcon(html: html, baseURL: pageURL) {
            // Declared is not delivered: sites carry the tag while the
            // address behind it serves a dead frontend-version path. An
            // unusable answer falls through to the sibling stage rather
            // than ending the chain on the strength of a tag.
            switch await fetch(icon) {
            case .data(let body) where RadioLogoLookup.usableLogo(body):
                return .hit(icon, commonsFile: nil, stage: "homepage")
            case .failed:
                return .failed("homepage-icon")
            default:
                break
            }
        }
        // Stage 3: the SIBLING entries of the same station. The
        // catalog carries a station several times, and the entry with the most
        // votes is not always the one with a picture. bigFM Deutschland has
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
            // Two search terms. The declared stem first, then the
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
                    // Verified before it counts, with the shared booking
                    // probe: reachable is not usable, and a stranger's
                    // favicon can be an error page or a stamp.
                    if case .data(let body) = await fetch(favicon),
                       RadioLogoLookup.usableLogo(body) {
                        Logger.library.notice("RADIO logo chain: sibling favicon for \(name, privacy: .public)")
                        return .hit(favicon, commonsFile: nil, stage: "geschwister")
                    }
                }
            }
        }
        // The convention URL is a GUESS (`https://<host>/apple-touch-icon.png`),
        // and a guess must not be booked as a finding: a station whose site has
        // no such file got a stored "logo" that answers 404 forever, and a
        // positive never expires. So the tile showed letters and never asked
        // again. It is checked before it counts.
        if let convention = RadioLogoLookup.conventionTouchIconURL(homepage: pageURL) {
            switch await fetch(convention) {
            case .data(let body) where RadioLogoLookup.usableLogo(body):
                return .hit(convention, commonsFile: nil, stage: "konvention")
            case .data, .empty:
                // The host answered, and what lies there is no usable
                // logo: nothing, an error page with status 200, or a
                // stamp below the gate. A clean no-hit. Bookable, and it
                // stops the guess being retried.
                return .noHit
            case .failed:
                // No answer says nothing about the station: not a
                // no-hit either, so nothing is written down.
                return .failed("convention-icon")
            }
        }
        return .noHit
    }
}
