// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation

/// Internet radio. The Foundation-only core (MaerCore rule: no UI
/// imports; Android groundwork). A station is LIVE audio: no duration, no
/// position, no download. The capability flags stay honest (see
/// RadioProvider).
nonisolated struct RadioStation: Codable, Identifiable, Hashable, Sendable {
    /// Namespaced id: `radio:rb:<stationuuid>` (Radio Browser catalog) or
    /// `radio:manual:<uuid>` (user-entered stream URL).
    let id: String
    let name: String
    /// The resolved STREAM url (Radio Browser's `url_resolved` when present).
    let streamURL: String
    var faviconURL: String? = nil
    var homepage: String? = nil
    var countryCode: String? = nil
    var tags: [String] = []
    /// Stream quality. Drives which codec/bitrate variant survives the
    /// name-based collapse.
    var bitrate: Int? = nil
    var codec: String? = nil
    /// RB vote mass. The regional socket/floor decides on it.
    var votes: Int? = nil
    /// Teil 1: the sibling codec/bitrate variants of this station (the collapse
    /// keeps the best as default and attaches ALL variants here, self included).
    /// Optional so already-persisted stations decode unchanged (no key → nil);
    /// nested variants are always flattened to nil (no recursion).
    var variants: [RadioStation]? = nil
    /// Lowercased ISO language codes, for the genre pages' sorting
    /// bonus. OPTIONAL for the same reason as `variants`. A synthesized
    /// decoder does NOT fall back to a property's default value on a missing
    /// key, it throws, and every already-stored favorite lacks this key.
    var languageCodes: [String]? = nil

    var isManual: Bool { id.hasPrefix(ItemNamespace.radioManualPrefix) }

    /// The variant list (self included) or empty when this station has no
    /// alternatives. The picker only appears for two or more.
    var variantList: [RadioStation] { variants ?? [] }

    /// The streams the station page lists: the variants when there are
    /// alternatives, else the station's own stream. Never empty, a station
    /// is at least one stream.
    var streamVariants: [RadioStation] {
        if !variantList.isEmpty { return variantList }
        var own = self
        own.variants = nil
        return [own]
    }

    /// The host that serves this stream, nil when the address names none.
    var streamHost: String? {
        guard let host = URL(string: streamURL)?.host(), !host.isEmpty else { return nil }
        return host
    }

    /// Teil 1: human label for the variant picker. "128 kbps · MP3", one part,
    /// or a generic fallback. Foundation-only (like the curated genre titles).
    var qualityLabel: String {
        var parts: [String] = []
        if let bitrate, bitrate > 0 { parts.append("\(bitrate) kbps") }
        if let codec, !codec.isEmpty { parts.append(codec.uppercased()) }
        return parts.isEmpty ? String(localized: "Stream") : parts.joined(separator: " · ")
    }

    // Identity is the namespaced id. The attached variants/quality never change
    // WHICH station this is, and id-based identity keeps store/dedupe lookups and
    // value-based navigation stable regardless of the transient variant payload.
    static func == (l: RadioStation, r: RadioStation) -> Bool { l.id == r.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

/// Radio Browser API station payload (subset). The API is an OPEN catalog.
/// No key; served by volunteer MIRRORS, so the same station can arrive from
/// several servers: de-dupe strictly by `stationuuid`.
nonisolated struct RadioBrowserStation: Decodable, Sendable {
    let stationuuid: String
    let name: String
    let url: String
    let urlResolved: String?
    let favicon: String?
    let homepage: String?
    let countrycode: String?
    let tags: String?
    let bitrate: Int?
    let codec: String?
    let votes: Int?
    /// ISO codes, comma-separated, mixed case in the wire data
    /// (`de` and `DE` both occur. Measured). Sorting bonus only, never a
    /// filter: 27 % of Swiss and 30 % of Austrian stations leave it empty.
    let languagecodes: String?

    enum CodingKeys: String, CodingKey {
        case stationuuid, name, url, favicon, homepage, countrycode, tags, bitrate, codec, votes
        case languagecodes
        case urlResolved = "url_resolved"
    }
}

nonisolated enum RadioMapping {
    /// Map + de-dupe (mirror double-serves by stationuuid) + drop unusable
    /// entries (empty name/url), then fold codec/bitrate variants. Order
    /// preserved (the API ranks by votes/clicks).
    static func stations(from raw: [RadioBrowserStation]) -> [RadioStation] {
        var seen = Set<String>()
        var result: [RadioStation] = []
        for s in raw {
            let stream = (s.urlResolved?.isEmpty == false ? s.urlResolved! : s.url)
                .trimmingCharacters(in: .whitespaces)
            let name = s.name.trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty, !stream.isEmpty, URL(string: stream) != nil,
                  seen.insert(s.stationuuid).inserted else { continue }
            result.append(RadioStation(
                id: ItemNamespace.radioBrowserPrefix + s.stationuuid,
                name: name,
                streamURL: stream,
                faviconURL: s.favicon?.isEmpty == false ? s.favicon : nil,
                homepage: s.homepage?.isEmpty == false ? s.homepage : nil,
                countryCode: s.countrycode?.isEmpty == false ? s.countrycode : nil,
                tags: (s.tags ?? "").split(separator: ",").map(String.init).filter { !$0.isEmpty },
                bitrate: (s.bitrate ?? 0) > 0 ? s.bitrate : nil,
                codec: s.codec?.isEmpty == false ? s.codec : nil,
                votes: s.votes,
                languageCodes: Self.languageCodes(from: s.languagecodes)))
        }
        return collapseVariants(result)
    }

    /// Comma-separated wire form → lowercased codes. Absent or empty stays
    /// nil: "no statement" and "the empty statement" are the same thing here,
    /// and the ranking must not punish either.
    static func languageCodes(from raw: String?) -> [String]? {
        let codes = (raw ?? "").split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            .filter { !$0.isEmpty }
        return codes.isEmpty ? nil : codes
    }

    /// Fold codec/bitrate VARIANTS of the same station (same normalized
    /// name + country) into ONE hit. The variants carry distinct stationuuids,
    /// so they pass the uuid de-dupe legitimately; here they collapse to the
    /// highest-bitrate variant (tie-break: prefer MP3), so the default plays the
    /// best stream. Per-variant selection comes later. First-appearance order
    /// (i.e. the highest-voted variant's position) is preserved.
    static func collapseVariants(_ stations: [RadioStation]) -> [RadioStation] {
        // Greedy grouping instead of a plain name|country key. Radio
        // Browser reports the SAME station's country inconsistently ("DE" on one
        // variant, empty on the next), which split e.g. Deutschlandfunk into two
        // buckets. Country is now only a SEPARATOR when two variants carry two
        // DIFFERENT non-empty codes; empty/nil is compatible with anything of the
        // same name. Each bucket tracks its first non-empty code as the effective
        // country, so an empty-country variant can't glue two real countries
        // together. Not a plain equivalence (compatibility isn't transitive), so
        // it can't be a hash key. A linear scan over the (≤40) buckets.
        var buckets: [(name: String, country: String?, members: [RadioStation])] = []
        for station in stations {
            let name = normalizedStationName(station.name)
            let code = normalizedCountry(station.countryCode)
            // Spacing variants of ONE brand ("Iran International" vs
            // "iraninternational") fold only with the SAME homepage domain
            // as witness. Never on the squeezed name alone (two real
            // stations may share a squeezed name; the domain separates them).
            let spaceless = name.replacingOccurrences(of: " ", with: "")
            let host = PodcastIdentity.feedHost(station.homepage ?? "")
            var flat = station; flat.variants = nil   // never nest variants
            if let idx = buckets.firstIndex(where: { bucket in
                guard countryCompatible(bucket: bucket.country, station: code) else { return false }
                if bucket.name == name { return true }
                return !host.isEmpty
                    && bucket.name.replacingOccurrences(of: " ", with: "") == spaceless
                    && bucket.members.contains {
                        PodcastIdentity.feedHost($0.homepage ?? "") == host
                    }
            }) {
                if let code, buckets[idx].country == nil { buckets[idx].country = code }
                buckets[idx].members.append(flat)
            } else {
                buckets.append((name: name, country: code, members: [flat]))
            }
        }
        // Teil 1: rank each bucket (best first) and let the surviving best carry
        // the full variant list (self included) so the detail page can offer a
        // picker. Bucket order = first appearance (the highest-voted variant's
        // position), preserved.
        return buckets.map { bucket in
            let ranked = bucket.members.sorted { prefers($0, over: $1) }
            var best = ranked[0]
            best.variants = ranked.count > 1 ? ranked : nil
            return best
        }
    }

    /// Teil 1 (pure): a STABLE key for a station's variant selection. Survives
    /// catalog rotation (a different variant winning the collapse) because it
    /// keys on the normalized name + country, not the volatile stationuuid.
    static func variantKey(for station: RadioStation) -> String {
        normalizedStationName(station.name) + "|" + (normalizedCountry(station.countryCode) ?? "")
    }

    /// Teil 1 (pure): resolve the stream to play. The user's persisted variant
    /// choice when it still exists among the station's variants, else the best
    /// (default) stream.
    static func effectiveStreamURL(for station: RadioStation, selectedURL: String?) -> String {
        guard let selectedURL, station.variantList.count > 1,
              station.variantList.contains(where: { $0.streamURL == selectedURL }) else {
            return station.streamURL
        }
        return selectedURL
    }

    private static func normalizedCountry(_ raw: String?) -> String? {
        let c = (raw ?? "").trimmingCharacters(in: .whitespaces).lowercased()
        return c.isEmpty ? nil : c
    }

    /// Compatible unless BOTH the bucket's effective country and the station's
    /// are non-empty AND differ. So a missing code never separates.
    private static func countryCompatible(bucket: String?, station: String?) -> Bool {
        guard let station, let bucket else { return true }
        return bucket == station
    }

    /// DISPLAY name. Station names carry pipe-separated junk
    /// ("Deutschlandfunk Kultur | DLF | …"): cut at the first hard separator
    /// when a real name remains. Display only (keys keep the full fold);
    /// ONE function for every player-context title.
    static func displayName(_ raw: String) -> String {
        var trimmed = raw.trimmingCharacters(in: .whitespaces)
        for separator in ["|", "•", "–", "—"] {
            if let idx = trimmed.range(of: separator)?.lowerBound {
                let head = trimmed[..<idx].trimmingCharacters(in: .whitespaces)
                if head.count >= 3 { trimmed = head; break }
            }
        }
        // Nachtrag (4): codec/bitrate TAIL junk without a separator
        // ("Deutschlandfunk AAC 192k"). Strip trailing decorations only;
        // the ORIGINAL name stays in detail/search.
        // After a codec no letter, digit or plus may follow, instead of a
        // word boundary: "AAC+" at the end has none after its plus.
        let tailJunk = "((\\b(mp3|aac\\+?|he-?aac\\+?|opus|ogg|vorbis|flac|wma)(?![\\p{L}\\p{N}+])|\\b\\d{2,3}\\s?k(bps)?\\b|\\bstream\\s?\\d+\\b)[\\s.]*)+$"
        let stripped = trimmed.replacingOccurrences(
            of: tailJunk, with: "", options: [.regularExpression, .caseInsensitive])
            .trimmingCharacters(in: .whitespaces)
        return stripped.count >= 3 ? stripped : trimmed
    }

    /// Strip codec/bitrate decorations and separators so variants of a station
    /// share a grouping key ("Deutschlandfunk | DLF | MP3 128k" →
    /// "deutschlandfunk dlf").
    static func normalizedStationName(_ name: String) -> String {
        var s = name.lowercased()
        for pattern in ["\\b(mp3|aac\\+?|he-?aac\\+?|opus|ogg|vorbis|flac|wma)(?![\\p{L}\\p{N}+])",
                        "\\b\\d{2,3}\\s?k(bps)?\\b"] {
            s = s.replacingOccurrences(of: pattern, with: " ", options: .regularExpression)
        }
        s = s.replacingOccurrences(of: "[|/•\\-–—]+", with: " ", options: .regularExpression)
        s = s.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        return s.trimmingCharacters(in: .whitespaces)
    }

    private static func prefers(_ a: RadioStation, over b: RadioStation) -> Bool {
        let ba = a.bitrate ?? 0, bb = b.bitrate ?? 0
        if ba != bb { return ba > bb }
        // Codec preference AAC > MP3.
        let aAAC = a.codec?.lowercased().contains("aac") == true
        let bAAC = b.codec?.lowercased().contains("aac") == true
        return aAAC && !bAAC
    }

    /// In a list fetched WITH a country filter, an entry
    /// whose country code belongs to a DIFFERENT country is dropped. Empty
    /// codes stay. Radio Browser reports countries patchily, and in this
    /// context "empty" means "belongs to the queried country", not "fits
    /// everything". The merge path reads it the second way, which is right
    /// without a country context and wrong inside one.
    static func keepingCountry(_ countryCode: String, in stations: [RadioStation]) -> [RadioStation] {
        let wanted = countryCode.trimmingCharacters(in: .whitespaces).uppercased()
        guard !wanted.isEmpty else { return stations }
        return stations.filter { station in
            let code = (station.countryCode ?? "").trimmingCharacters(in: .whitespaces).uppercased()
            return code.isEmpty || code == wanted
        }
    }

    /// Sender-Dedupe: RB serves the same station multiply (stream
    /// variants, stale twins). Identity = display-normalized name PLUS the
    /// homepage/stream DOMAIN as the second key. A same-named FOREIGN
    /// station (different domain) never folds in (the Rock-Antenne-Italy
    /// class); real program siblings (1LIVE vs 1LIVE Dance Hits) differ by
    /// name and never fold either. The best entry is shown (bitrate,
    /// AAC>MP3), and every stream address of the bundle rides in its
    /// `variants` once (`bundleStreams`), the ones each entry brought
    /// included, so the
    /// detail page offers them instead of throwing them away.
    static func dedupeForDisplay(_ stations: [RadioStation]) -> [RadioStation] {
        var shown: [String: RadioStation] = [:]
        var streams: [String: [RadioStation]] = [:]
        var order: [String] = []
        for station in stations {
            let key = displayIdentityKey(station)
            let own = [strippedVariant(station)] + station.variantList.map(strippedVariant)
            if let existing = shown[key] {
                if prefers(station, over: existing) { shown[key] = station }
            } else {
                shown[key] = station
                order.append(key)
            }
            streams[key, default: []] += own
        }
        return order.compactMap { key in
            guard var entry = shown[key] else { return nil }
            entry.variants = bundleStreams(shown: entry, among: streams[key] ?? [])
            return entry
        }
    }

    /// The streams of one bundle, each stream address once: the shown entry
    /// first (the house rule: the station is one of its own streams), the
    /// others best first. A stream is its address, not its id: Radio
    /// Browser lists one address under several ids, and the choice keys on
    /// the address (`RadioStore.selectedVariantURL`). Of several ids of one
    /// address the shown entry stays, else the best. Nil when the bundle
    /// holds a single stream.
    static func bundleStreams(shown: RadioStation, among all: [RadioStation]) -> [RadioStation]? {
        var best: [String: RadioStation] = [:]
        var addresses: [String] = []
        for stream in all where stream.streamURL != shown.streamURL {
            if let held = best[stream.streamURL] {
                if prefers(stream, over: held) { best[stream.streamURL] = stream }
            } else {
                best[stream.streamURL] = stream
                addresses.append(stream.streamURL)
            }
        }
        let others = addresses.compactMap { best[$0] }
        let list = [strippedVariant(shown)] + others.sorted { prefers($0, over: $1) }
        return list.count > 1 ? list : nil
    }

    private static func strippedVariant(_ station: RadioStation) -> RadioStation {
        var flat = station
        flat.variants = nil   // never nest
        return flat
    }

    /// Identity key: folded display name + comparable domain (homepage
    /// preferred. CDN stream hosts differ between real variants).
    static func displayIdentityKey(_ station: RadioStation) -> String {
        let name = RadioBrowseCuration.mergeKey(displayName(station.name))
        let domainSource = station.homepage?.isEmpty == false ? station.homepage! : station.streamURL
        return name + "|" + PodcastIdentity.feedHost(domainSource)
    }

    /// A user-entered stream (name + URL). Nil when the URL is unusable.
    static func manualStation(name: String, urlString: String,
                              id: String = ItemNamespace.radioManualPrefix + UUID().uuidString) -> RadioStation? {
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        let trimmedURL = urlString.trimmingCharacters(in: .whitespaces)
        guard !trimmedName.isEmpty, let url = URL(string: trimmedURL),
              url.scheme?.hasPrefix("http") == true else { return nil }
        return RadioStation(id: id, name: trimmedName, streamURL: trimmedURL)
    }
}

/// ICY/shoutcast in-stream metadata. The timed-metadata frame usually
/// carries `StreamTitle='Artist - Title';`. Pure parser: splits into
/// artist/title when the conventional " - " separator is present, otherwise
/// everything is the title.
nonisolated enum ICYMetadata {
    static func parse(streamTitle raw: String) -> (title: String, artist: String?)? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let parts = trimmed.components(separatedBy: " - ")
        if parts.count >= 2 {
            let artist = parts[0].trimmingCharacters(in: .whitespaces)
            let title = parts.dropFirst().joined(separator: " - ").trimmingCharacters(in: .whitespaces)
            if !artist.isEmpty, !title.isEmpty { return (title, artist) }
        }
        return (trimmed, nil)
    }
}

/// Local station lists. Favorites and manual stations (persisted), plus
/// the last-heard ring. UserDefaults-backed like RecentSearches; stations are
/// stored WHOLE (the catalog is volatile, favorites must survive it).
nonisolated enum RadioStore {
    static let favoritesKey = "radioFavorites"
    static let manualKey = "radioManualStations"
    static let recentsKey = "radioRecents"
    static let recentsCap = 8
    // Teil 3: play-frequency ("Most Played"). The counts are the source of
    // truth; the whole stations are stored alongside so the row stays resolvable
    // after the volatile catalog rotates (like recents). The store is bounded by
    // keeping the top-ranked entries, so a heavy favorite is never evicted.
    static let playCountsKey = "radioPlayCounts"
    static let mostPlayedKey = "radioMostPlayedStations"
    static let mostPlayedStoreCap = 40

    private static func load(_ key: String, defaults: UserDefaults) -> [RadioStation] {
        guard let data = defaults.data(forKey: key),
              let stations = try? JSONDecoder().decode([RadioStation].self, from: data) else { return [] }
        return stations
    }

    /// A list that stands and does not decode reads as none (`load`); the
    /// next write sets it aside first instead of replacing it for good.
    private static func save(_ stations: [RadioStation], _ key: String, defaults: UserDefaults) {
        CorruptStore.setAsideUnreadable([RadioStation].self, defaultsKey: key, defaults: defaults,
                                        label: "RADIO \(key)")
        if let data = try? JSONEncoder().encode(stations) {
            defaults.set(data, forKey: key)
        }
    }

    static func favorites(defaults: UserDefaults = .standard) -> [RadioStation] {
        load(favoritesKey, defaults: defaults)
    }

    static func isFavorite(_ id: String, defaults: UserDefaults = .standard) -> Bool {
        favorites(defaults: defaults).contains { $0.id == id }
    }

    /// MainActor: toggling is a user statement. It notes into the choice
    /// family (event time, tombstone on removal). All callers are UI.
    @MainActor
    static func toggleFavorite(_ station: RadioStation, defaults: UserDefaults = .standard) {
        var list = favorites(defaults: defaults)
        let removed: Bool
        if let idx = list.firstIndex(where: { $0.id == station.id }) {
            list.remove(at: idx)
            removed = true
        } else {
            list.append(station)
            removed = false
        }
        save(list, favoritesKey, defaults: defaults)
        UserChoiceCloudSync.shared.noteFavorite(station, added: !removed)
    }

    /// Adoption path of the choice family. Replaces the list WITHOUT noting
    /// (a reconcile is not a user action).
    static func replaceFavorites(_ list: [RadioStation], defaults: UserDefaults = .standard) {
        save(list, favoritesKey, defaults: defaults)
    }

    static func manualStations(defaults: UserDefaults = .standard) -> [RadioStation] {
        load(manualKey, defaults: defaults)
    }

    static func addManual(_ station: RadioStation, defaults: UserDefaults = .standard) {
        var list = manualStations(defaults: defaults)
        list.removeAll { $0.id == station.id }
        list.append(station)
        save(list, manualKey, defaults: defaults)
    }

    /// A person entered this station: it travels to the other device as its
    /// own statement, stamped with the moment of adding.
    @MainActor
    static func addManualNoting(_ station: RadioStation, defaults: UserDefaults = .standard) {
        addManual(station, defaults: defaults)
        UserChoiceCloudSync.shared.noteManualStation(station, removed: false)
    }

    /// The adoption path: writes the station WITHOUT noting, because a
    /// reconcile is not a user action.
    static func addManualAdopted(_ station: RadioStation, defaults: UserDefaults = .standard) {
        addManual(station, defaults: defaults)
    }

    static func removeManual(_ id: String, defaults: UserDefaults = .standard) {
        var list = manualStations(defaults: defaults)
        list.removeAll { $0.id == id }
        save(list, manualKey, defaults: defaults)
    }

    /// A person deleted the station: the removal travels as its tombstone.
    @MainActor
    static func removeManualNoting(_ id: String, defaults: UserDefaults = .standard) {
        let station = manualStations(defaults: defaults).first { $0.id == id }
        removeManual(id, defaults: defaults)
        if let station { UserChoiceCloudSync.shared.noteManualStation(station, removed: true) }
    }

    /// Last-heard ring: newest first, de-duped, capped.
    static func recents(defaults: UserDefaults = .standard) -> [RadioStation] {
        load(recentsKey, defaults: defaults)
    }

    static func recordRecent(_ station: RadioStation, defaults: UserDefaults = .standard) {
        var list = recents(defaults: defaults)
        list.removeAll { $0.id == station.id }
        list.insert(station, at: 0)
        save(Array(list.prefix(recentsCap)), recentsKey, defaults: defaults)
        // The MRU ORDER alone cannot be merged with another class. A
        // joint "recently played" row needs a comparable TIME. Kept beside
        // the ring (not inside the station), so nothing about the station
        // model changes.
        var stamps = storedRecentTimes(defaults: defaults)
        stamps[station.id] = Date().timeIntervalSince1970
        let live = Set(recents(defaults: defaults).map(\.id))
        defaults.set(stamps.filter { live.contains($0.key) }, forKey: recentTimesKey)
    }

    /// The play is a user statement: it notes into the choice family so the
    /// ring travels (the play moment is the time, a removal the tombstone).
    @MainActor
    static func recordRecentNoting(_ station: RadioStation, defaults: UserDefaults = .standard) {
        recordRecent(station, defaults: defaults)
        UserChoiceCloudSync.shared.noteRecentStation(station, removed: false)
    }

    /// Adoption path of the choice family: replaces ring and times WITHOUT
    /// noting (a reconcile is not a user action).
    static func replaceRecents(_ list: [RadioStation], times: [String: Double],
                               defaults: UserDefaults = .standard) {
        save(Array(list.prefix(recentsCap)), recentsKey, defaults: defaults)
        let live = Set(list.prefix(recentsCap).map(\.id))
        defaults.set(times.filter { live.contains($0.key) }, forKey: recentTimesKey)
    }

    static func removeRecent(id: String, defaults: UserDefaults = .standard) {
        var list = recents(defaults: defaults)
        list.removeAll { $0.id == id }
        save(list, recentsKey, defaults: defaults)
        defaults.set(storedRecentTimes(defaults: defaults).filter { $0.key != id }, forKey: recentTimesKey)
    }

    /// "Remove from Listen Again": the removal is a statement that travels
    /// as the station's tombstone, and the rows recompute at once.
    @MainActor
    static func removeRecentNoting(_ station: RadioStation, defaults: UserDefaults = .standard) {
        removeRecent(id: station.id, defaults: defaults)
        UserChoiceCloudSync.shared.noteRecentStation(station, removed: true)
        NotificationCenter.default.post(name: .continueHiddenChanged, object: nil)
    }

    static let recentTimesKey = "radioRecentTimes"

    /// station id → last played (seconds). Missing for stations heard before
    /// this existed, and missing for an entry the ring kept without a
    /// moment. Both are the same thing, and the caller ranks them after the
    /// dated ones instead of inventing a time.
    ///
    /// The rule sits here, where the time leaves the store, so no surface
    /// has to answer it a second time.
    static func recentTimes(defaults: UserDefaults = .standard) -> [String: Double] {
        storedRecentTimes(defaults: defaults).compactMapValues(RecentlyPlayedRow.knownTime)
    }

    /// The dictionary as it lies, for the two bookkeeping paths that read it
    /// and write it straight back. They must not turn the reading rule above
    /// into a silent rewrite of what is stored.
    private static func storedRecentTimes(defaults: UserDefaults = .standard) -> [String: Double] {
        (defaults.dictionary(forKey: recentTimesKey) as? [String: Double]) ?? [:]
    }

    /// Every station the person keeps (favorites, manual, recents), each
    /// once, in that order: what resolves by id beyond this session.
    static func onHand(defaults: UserDefaults = .standard) -> [RadioStation] {
        var seen = Set<String>()
        return (favorites(defaults: defaults) + manualStations(defaults: defaults) + recents(defaults: defaults))
            .filter { seen.insert($0.id).inserted }
    }

    /// Resolve any known station by id (favorites, manual, recents).
    static func station(forId id: String, defaults: UserDefaults = .standard) -> RadioStation? {
        onHand(defaults: defaults).first { $0.id == id }
    }

    /// A station's name from every stock that keeps one, the most-played
    /// store included: "Listen Again" holds only eight, so a station heard
    /// for hours drops out of it while the statistics still count it.
    /// Naming only; playing resolves through `station(forId:)`.
    static func stationName(forId id: String, defaults: UserDefaults = .standard) -> String? {
        (station(forId: id, defaults: defaults) ?? load(mostPlayedKey, defaults: defaults).first { $0.id == id })?.name
    }

    // MARK: - Last composed discovery rows (cold-start frame 1)

    static let discoveryCacheKey = "radioDiscoveryCache"

    nonisolated struct DiscoveryCache: Codable {
        var popular: [RadioStation]
        var regional: [RadioStation]
        /// The rotation day the rows were composed for. A NEW day recomputes
        /// (showing this stale state until the fresh one lands, never blank).
        var day: Int
    }

    /// What a discovery run does with its answer.
    nonisolated enum DiscoveryStep: Equatable, Sendable {
        /// The run answered: its rows replace the shown ones and the cache.
        case replace
        /// The run failed while rows stand (shown or from the cache): they
        /// stay, the cache is not written, and the run does not count as
        /// loaded, so the next try stays free. Stale beats blank.
        case keep
        /// The run failed and nothing stands: the section says so with a
        /// way back in.
        case failed
    }

    /// Whether the regional fetch failed as a whole, pure: one answer per
    /// name variant (true when at least one of its two lists came back). A
    /// state with no variant asked did not fail; a run in which every
    /// variant failed did, and is no empty success.
    nonisolated static func regionFailed(variantAnswered: [Bool]) -> Bool {
        !variantAnswered.isEmpty && !variantAnswered.contains(true)
    }

    /// The step of a run, pure: a failed run never replaces what stands.
    nonisolated static func discoveryStep(failed: Bool, standing: Bool) -> DiscoveryStep {
        guard failed else { return .replace }
        return standing ? .keep : .failed
    }

    static func saveDiscovery(popular: [RadioStation], regional: [RadioStation],
                              day: Int, defaults: UserDefaults = .standard) {
        let cache = DiscoveryCache(popular: popular, regional: regional, day: day)
        if let data = try? JSONEncoder().encode(cache) {
            defaults.set(data, forKey: discoveryCacheKey)
        }
    }

    static func cachedDiscovery(defaults: UserDefaults = .standard) -> DiscoveryCache? {
        guard let data = defaults.data(forKey: discoveryCacheKey) else { return nil }
        return try? JSONDecoder().decode(DiscoveryCache.self, from: data)
    }

    // MARK: - Teil 3: play frequency

    static func playCounts(defaults: UserDefaults = .standard) -> [String: Int] {
        guard let data = defaults.data(forKey: playCountsKey),
              let counts = try? JSONDecoder().decode([String: Int].self, from: data) else { return [:] }
        return counts
    }

    private static func savePlayCounts(_ counts: [String: Int], defaults: UserDefaults) {
        CorruptStore.setAsideUnreadable([String: Int].self, defaultsKey: playCountsKey, defaults: defaults,
                                        label: "RADIO play counts")
        if let data = try? JSONEncoder().encode(counts) { defaults.set(data, forKey: playCountsKey) }
    }

    /// Count one play of `station` and keep its record resolvable. Bounded: when
    /// the store overflows it is trimmed to the top-ranked entries (ties → most
    /// recent), so a station played a lot is never dropped for a rarely-heard one.
    static func recordPlay(_ station: RadioStation, defaults: UserDefaults = .standard) {
        var counts = playCounts(defaults: defaults)
        counts[station.id, default: 0] += 1
        var stored = load(mostPlayedKey, defaults: defaults)
        stored.removeAll { $0.id == station.id }
        stored.append(station)   // append = most-recent, the tie-break anchor
        if stored.count > mostPlayedStoreCap {
            stored = RadioRanking.mostPlayed(stations: stored, counts: counts, limit: mostPlayedStoreCap)
        }
        savePlayCounts(counts, defaults: defaults)
        save(stored, mostPlayedKey, defaults: defaults)
    }

    /// Stations ranked by listening TIME (desc), capped. The "Most Played" row.
    /// The seconds come in as a parameter because they live in the statistics
    /// store, which is main-actor bound while this type is not; passing them
    /// keeps the store pure and the rule testable.
    static func mostPlayed(limit: Int = 8, seconds: [String: Int] = [:],
                           defaults: UserDefaults = .standard) -> [RadioStation] {
        RadioRanking.mostPlayed(stations: load(mostPlayedKey, defaults: defaults),
                                counts: playCounts(defaults: defaults),
                                seconds: seconds, limit: limit)
    }

    // MARK: - Teil 1: per-station codec/bitrate variant selection

    static let variantSelectionKey = "radioVariantSelection"   // [variantKey: streamURL]

    private static func variantSelections(defaults: UserDefaults) -> [String: String] {
        (defaults.dictionary(forKey: variantSelectionKey) as? [String: String]) ?? [:]
    }

    /// The persisted variant stream URL for a station, or nil for the default.
    static func selectedVariantURL(for station: RadioStation, defaults: UserDefaults = .standard) -> String? {
        variantSelections(defaults: defaults)[RadioMapping.variantKey(for: station)]
    }

    /// Persist a variant choice; passing the station's default (best) stream
    /// clears the override so the station tracks the catalog's best again.
    /// The choice travels as its own statement (`radioVariant.<key>`), a
    /// clear as its tombstone.
    @MainActor
    static func setSelectedVariant(_ streamURL: String, for station: RadioStation,
                                   defaults: UserDefaults = .standard) {
        var dict = variantSelections(defaults: defaults)
        let key = RadioMapping.variantKey(for: station)
        if streamURL == station.streamURL { dict[key] = nil } else { dict[key] = streamURL }
        defaults.set(dict, forKey: variantSelectionKey)
        UserChoiceCloudSync.shared.noteVariant(key: key, streamURL: dict[key])
    }

    /// The adoption path: writes without noting (a reconcile is not a user
    /// action). Nil clears the choice.
    static func setSelectedVariantAdopted(key: String, streamURL: String?,
                                          defaults: UserDefaults = .standard) {
        var dict = variantSelections(defaults: defaults)
        dict[key] = streamURL
        defaults.set(dict, forKey: variantSelectionKey)
    }

    /// Every variant choice as key/value, for the reconcile.
    static func allVariantSelections(defaults: UserDefaults = .standard) -> [String: String] {
        variantSelections(defaults: defaults)
    }
}

/// Teil 3 (pure, tested): rank stations by play frequency. Positive counts only,
/// descending; ties keep the later-stored (more-recently-played) station first;
/// capped. Foundation-only (MaerCore rule). No store, no UI.
nonisolated enum RadioRanking {
    /// "Most listened", ranked by TIME.
    ///
    /// Starts were the wrong measure and it took the honest counting to make
    /// that visible: a station tapped and left after ten seconds weighed as
    /// much as two hours. For a live stream the time listened is the only
    /// truthful answer to "a lot".
    ///
    /// **ONE ranking, not two lists.** Seconds are the measure; the start count
    /// is a FALLBACK for stations that have no measured time yet, and it stops
    /// applying to a station the moment seconds exist for it. Two parallel
    /// rankings merged afterwards would be the second version this project
    /// keeps abolishing. And the boundary between them would be arbitrary.
    ///
    /// Without the fallback the row would stand empty right after the update
    /// (nobody has measured seconds yet). The transition would look like a
    /// defect, and a person cannot tell "new measure" from "lost my history".
    static func mostPlayed(stations: [RadioStation], counts: [String: Int],
                           seconds: [String: Int] = [:], limit: Int) -> [RadioStation] {
        guard limit > 0 else { return [] }
        // A station is on the list if EITHER measure knows it.
        func weight(_ id: String) -> (measured: Bool, value: Int) {
            if let s = seconds[id], s > 0 { return (true, s) }
            return (false, counts[id] ?? 0)
        }
        return stations.enumerated()
            .filter { weight($0.element.id).value > 0 }
            .sorted { a, b in
                let wa = weight(a.element.id), wb = weight(b.element.id)
                // Measured time outranks an estimate. A station with real
                // seconds is never pushed below one that only has taps.
                if wa.measured != wb.measured { return wa.measured }
                if wa.value != wb.value { return wa.value > wb.value }
                return a.offset > b.offset   // tie → more recently stored wins
            }
            .prefix(limit)
            .map(\.element)
    }
}

/// One curated genre. A Radio Browser tag with a display name
/// and an SF Symbol. Foundation-only (MaerCore rule): the glyph is just a name
/// string, the view renders it.
nonisolated struct RadioGenre: Identifiable, Equatable, Sendable {
    let tag: String          // exact Radio Browser tag (bytagexact)
    let systemImage: String
    let title: String
    var id: String { tag }
}

/// Radio-Picker-Kuratierung: one raw name+stationcount entry of the
/// Radio Browser `states`/`countries` lists (community data. Variants,
/// junk, cities next to real regions).
nonisolated struct RadioBrowseEntry: Equatable, Sendable {
    let name: String
    let stationCount: Int
}

/// Pure curation of the raw Radio Browser region/country lists (tested with
/// the real Swiss fixture). Rules. Deliberately COUNTRY-AGNOSTIC, no
/// hardcoded canton list:
/// 1. Noise filter: empty/whitespace, purely numeric names, and entries whose
///    MERGED station count stays below the threshold are dropped.
/// 2. Variant merge: case- and diacritic-insensitive (and whitespace-trimmed)
///    dedupe. "Zürich"/"Zurich"/" Zürich" collapse; the variant with the
///    most stations names the entry, the by-state query then runs against
///    ALL merged raw names (otherwise the other spelling's stations vanish).
/// 3. Sort: merged station count descending (most relevant region first),
///    ties alphabetically.
nonisolated enum RadioBrowseCuration {
    struct Curated: Equatable, Identifiable, Sendable {
        /// Display name (the variant with the most stations).
        let display: String
        /// ALL raw names of the merged variants. Every one is queried.
        let queryNames: [String]
        /// Sum of the merged variants' station counts.
        let stationCount: Int
        var id: String { display }
    }

    /// Case-/diacritic-insensitive, trimmed merge key.
    static func mergeKey(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .lowercased()
    }

    static func curated(_ raw: [RadioBrowseEntry], minStations: Int = 2) -> [Curated] {
        var groups: [String: [RadioBrowseEntry]] = [:]
        var order: [String] = []
        for entry in raw {
            let trimmed = entry.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            guard trimmed.rangeOfCharacter(from: CharacterSet.decimalDigits.inverted) != nil else { continue }
            let key = mergeKey(trimmed)
            if groups[key] == nil { order.append(key) }
            // Keep the RAW name. `bystateexact` matches byte-exactly, a
            // trimmed " Zürich" would silently lose that variant's stations.
            groups[key, default: []].append(entry)
        }
        return order.compactMap { key -> Curated? in
            guard let variants = groups[key] else { return nil }
            let total = variants.reduce(0) { $0 + $1.stationCount }
            guard total >= minStations else { return nil }
            let winner = variants.max { a, b in
                a.stationCount == b.stationCount ? a.name > b.name : a.stationCount < b.stationCount
            }!
            var seenNames = Set<String>()
            return Curated(display: winner.name.trimmingCharacters(in: .whitespacesAndNewlines),
                           queryNames: variants.map(\.name).filter { seenNames.insert($0).inserted },
                           stationCount: total)
        }
        .sorted { a, b in
            a.stationCount == b.stationCount
                ? a.display.localizedCaseInsensitiveCompare(b.display) == .orderedAscending
                : a.stationCount > b.stationCount
        }
    }

    /// Picker search filter (pure): case-/diacritic-insensitive substring.
    /// Free text without a hit selects NOTHING (choice stays bound to
    /// existing entries).
    static func filtered(_ entries: [Curated], query: String) -> [Curated] {
        let q = mergeKey(query)
        guard !q.isEmpty else { return entries }
        return entries.filter { mergeKey($0.display).contains(q) }
    }
}

/// The country layer of the radio picker: every country with at least two
/// stations, in the order of its shown name (a list one searches by name,
/// not by size), and a search that asks names worked out once. Before, the
/// list stood by station count and every keystroke folded and localized
/// each country's name twice.
nonisolated enum RadioCountryList {
    struct Country: Equatable, Identifiable, Sendable {
        /// The code and the English name the states endpoint needs.
        let code: String
        let name: String
        /// The name in the language of the device.
        let shown: String
        let count: Int
        /// Both names folded once, apart so a hit never spans the two.
        let searchKey: String
        var id: String { code }
    }

    static func curated(_ raw: [(code: String, name: String, count: Int)],
                        shownName: (String) -> String?, minStations: Int = 2) -> [Country] {
        raw.filter { $0.count >= minStations }
            .map { entry in
                let shown = shownName(entry.code) ?? entry.name
                return Country(code: entry.code, name: entry.name, shown: shown, count: entry.count,
                               searchKey: RadioBrowseCuration.mergeKey(entry.name) + "\u{1F}"
                                   + RadioBrowseCuration.mergeKey(shown))
            }
            .sorted { $0.shown.localizedStandardCompare($1.shown) == .orderedAscending }
    }

    static func filtered(_ countries: [Country], query: String) -> [Country] {
        let q = RadioBrowseCuration.mergeKey(query)
        guard !q.isEmpty else { return countries }
        return countries.filter { $0.searchKey.contains(q) }
    }
}

/// Which country feeds "Popular in …" and the region list.
/// USER CHOICE BEATS GUESSING. Pure cascade: explicitly chosen country →
/// country implied by the chosen region → locale country. No location access.
/// "Beliebt in …" with a socket and a daily rotation. The eternal votes list never
/// changed. Pool = top votes + top clicktrend
/// (deduped); seats 1–3 = the CURRENT clicktrend top (the socket); the rest
/// drawn weighted with a DATE-seeded RNG (stable within the day. Calm-gate
/// spirit. Freshly mixed daily). Pure + tested; same mechanic for the
/// regional section.
nonisolated enum RadioRotation {
    /// yyyymmdd + country code → the day-stable seed.
    static func seed(day: Int, countryCode: String?) -> UInt64 {
        var hash: UInt64 = 1_469_598_103_934_665_603
        for byte in (countryCode ?? "").lowercased().utf8 {
            hash = (hash ^ UInt64(byte)) &* 1_099_511_628_211
        }
        return UInt64(bitPattern: Int64(day)) &* 100_003 &+ hash
    }

    static let socketSize = 3

    /// On STATE level clicktrend is noise-dominated. A webradio's mini
    /// click spike beats a nationwide station. The regional socket therefore
    /// sits on VOTES (stable mass); clicktrend only joins the draw pool when
    /// it clears a minimum-votes floor. National keeps the clicktrend
    /// socket.
    enum SocketSource { case clicktrend, votes }

    /// Minimum seats the VOTES fill keeps even when the core could
    /// fill the whole row. Webradios stay discoverable, they only leave the
    /// top positions.
    static let fillMinimum = 4

    /// Core-first composition. The first-hand core (published rank
    /// order) takes the head of the row, today's vote/trend pool fills the
    /// rest. Daily rotation runs WITHIN each pot: the core's top
    /// `socketSize` stay fixed (the row must read as "what the country
    /// really hears"), the remaining core seats draw day-seeded weighted by
    /// published rank; the fill pot rotates exactly like the coreless row.
    static func composeWithCore(core: [RadioStation],
                                votes: [RadioStation], clicktrend: [RadioStation],
                                seed: UInt64, limit: Int,
                                socket: SocketSource = .clicktrend,
                                minTrendVotes: Int = 0) -> [RadioStation] {
        guard !core.isEmpty else {
            return compose(votes: votes, clicktrend: clicktrend, seed: seed,
                           limit: limit, socket: socket, minTrendVotes: minTrendVotes)
        }
        let coreSeats = min(core.count, max(0, limit - fillMinimum))
        var out = Array(core.prefix(socketSize))
        // Remaining core seats: day-seeded weighted draw by published rank.
        var candidates = Array(core.dropFirst(socketSize))
        var generator = RediscoverSections.SplitMix64(seed: seed ^ 0x1_9a8b_4c)
        while out.count < coreSeats, !candidates.isEmpty {
            let poolMax = candidates.count + 1
            let weights = candidates.indices.map { UInt64(poolMax - $0) }
            let total = weights.reduce(0, +)
            var pick = generator.next() % max(total, 1)
            var chosen = 0
            for (index, weight) in weights.enumerated() {
                if pick < weight { chosen = index; break }
                pick -= weight
            }
            out.append(candidates.remove(at: chosen))
        }
        // Fill pot: the existing rotation over the pools, core rows excluded.
        // The identity key carries the DOMAIN, and
        // a core entry can resolve a different host than the catalog copy of
        // the same station (homepage vs. stream host fallback). So the fill
        // additionally excludes plain folded NAME matches. Within one
        // country's curated row, an equal folded name IS the same station.
        let coreKeys = Set(core.map { RadioMapping.displayIdentityKey($0) })
        let coreNames = Set(core.map { RadioBrowseCuration.mergeKey(RadioMapping.displayName($0.name)) })
        func isCore(_ station: RadioStation) -> Bool {
            coreKeys.contains(RadioMapping.displayIdentityKey(station))
                || coreNames.contains(RadioBrowseCuration.mergeKey(RadioMapping.displayName(station.name)))
        }
        let fill = compose(
            votes: votes.filter { !isCore($0) },
            clicktrend: clicktrend.filter { !isCore($0) },
            seed: seed, limit: limit - out.count,
            socket: socket, minTrendVotes: minTrendVotes)
        return out + fill
    }

    static func compose(votes: [RadioStation], clicktrend: [RadioStation],
                        seed: UInt64, limit: Int,
                        socket: SocketSource = .clicktrend,
                        minTrendVotes: Int = 0) -> [RadioStation] {
        guard limit > 0 else { return [] }
        // Votes floor for the trend ingredient (0 = off, national default).
        let clicktrend = minTrendVotes > 0
            ? clicktrend.filter { ($0.votes ?? 0) >= minTrendVotes }
            : clicktrend
        // Deduped pool with the best RANK from either list as the weight base.
        var rank: [String: Int] = [:]
        var byKey: [String: RadioStation] = [:]
        var order: [String] = []
        for list in [clicktrend, votes] {
            for (r, station) in list.enumerated() {
                let key = RadioMapping.displayIdentityKey(station)
                if let existing = rank[key] {
                    rank[key] = min(existing, r)
                } else {
                    rank[key] = r
                    byKey[key] = station
                    order.append(key)
                }
            }
        }
        // Socket: trend top (national) or votes top (regional, stable).
        let socketList = socket == .clicktrend ? clicktrend : votes
        var socketKeys: [String] = []
        for station in socketList {
            let key = RadioMapping.displayIdentityKey(station)
            if !socketKeys.contains(key) { socketKeys.append(key) }
            if socketKeys.count == socketSize { break }
        }
        var out = socketKeys.compactMap { byKey[$0] }
        // Rest: weighted draw without replacement, day-seeded.
        var candidates = order.filter { !socketKeys.contains($0) }
        var generator = RediscoverSections.SplitMix64(seed: seed)
        let poolMax = (candidates.map { rank[$0] ?? 0 }.max() ?? 0) + 1
        while out.count < limit, !candidates.isEmpty {
            let weights = candidates.map { UInt64(poolMax - (rank[$0] ?? 0)) }
            let total = weights.reduce(0, +)
            var pick = generator.next() % max(total, 1)
            var chosen = 0
            for (index, weight) in weights.enumerated() {
                if pick < weight { chosen = index; break }
                pick -= weight
            }
            let key = candidates.remove(at: chosen)
            if let station = byKey[key] { out.append(station) }
        }
        return out
    }
}

/// Canonical region tables for the CORE countries. DE/AT
/// Bundesländer, CH Kantone. This deliberately overrides the "no country
/// lists" rule: raw Radio-Browser state names (any language, abbreviation,
/// or typo variant) map onto ONE canon entry via aliases, the by-state
/// query then runs against ALL mapped raw names (existing merge mechanic).
/// Unmapped names pool into ONE trailing "Other" entry; nationwide
/// pseudo-states DROP (the "Popular in <country>" section carries them).
/// Countries without a table fall back to the generic curation. Pure data.
/// Extending a table is data entry, never new code.
nonisolated enum RadioRegionCanon {
    struct Entry {
        let display: String
        let aliases: [String]
        init(_ display: String, _ aliases: [String] = []) {
            self.display = display
            self.aliases = aliases
        }
    }

    /// Canon key: the curation merge key PLUS hyphen→space folding, so
    /// "Nordrhein Westfalen" and "Nordrhein-Westfalen" meet.
    static func canonKey(_ name: String) -> String {
        // eindampfen: punctuation folds to spaces so composed RB names
        // ("Bayern, München, AAC" · "Moers/NRW" · "Hessen (Kassel)") token-
        // ize cleanly for the subsequence match.
        var key = RadioBrowseCuration.mergeKey(name)
        for ch in ["-", ",", "/", "(", ")", ".", "|"] {
            key = key.replacingOccurrences(of: ch, with: " ")
        }
        return key.split(separator: " ").joined(separator: " ")
    }

    static let tables: [String: [Entry]] = [
        "DE": [
            Entry("Baden-Württemberg", ["BW", "Schwaben"]),
            Entry("Bayern", ["Bavaria", "BY"]),
            Entry("Berlin", ["BE", "Berlim", "Берлин"]),
            Entry("Brandenburg", ["BB"]),
            Entry("Bremen", ["HB"]),
            Entry("Hamburg", ["HH"]),
            Entry("Hessen", ["Hesse", "HE"]),
            Entry("Mecklenburg-Vorpommern", ["Mecklenburg-Western Pomerania", "MV", "Mecklenburg"]),
            Entry("Niedersachsen", ["Lower Saxony", "NI"]),
            Entry("Nordrhein-Westfalen", ["NRW", "North Rhine-Westphalia", "Northrhine Westphalia", "NW", "Westfalen", "Rheinland"]),
            Entry("Rheinland-Pfalz", ["Rhineland-Palatinate", "RLP", "RP", "Pfalz"]),
            Entry("Saarland", ["SL"]),
            Entry("Sachsen", ["Saxony", "SN"]),
            Entry("Sachsen-Anhalt", ["Saxony-Anhalt", "ST"]),
            Entry("Schleswig-Holstein", ["SH"]),
            Entry("Thüringen", ["Thuringia", "TH"]),
        ],
        "AT": [
            Entry("Burgenland"),
            Entry("Kärnten", ["Carinthia"]),
            Entry("Niederösterreich", ["Lower Austria"]),
            Entry("Oberösterreich", ["Upper Austria"]),
            Entry("Salzburg"),
            Entry("Steiermark", ["Styria"]),
            Entry("Tirol", ["Tyrol"]),
            Entry("Vorarlberg"),
            Entry("Wien", ["Vienna"]),
        ],
        "CH": [
            Entry("Zürich", ["ZH"]),
            Entry("Bern", ["Berne", "BE"]),
            Entry("Luzern", ["Lucerne", "LU"]),
            Entry("Uri", ["UR"]),
            Entry("Schwyz", ["SZ"]),
            Entry("Obwalden", ["OW"]),
            Entry("Nidwalden", ["NW"]),
            Entry("Glarus", ["GL"]),
            Entry("Zug", ["ZG"]),
            Entry("Freiburg", ["Fribourg", "FR"]),
            Entry("Solothurn", ["SO"]),
            Entry("Basel-Stadt", ["Basel City", "BS", "Basel"]),
            Entry("Basel-Landschaft", ["Baselland", "BL"]),
            Entry("Schaffhausen", ["SH"]),
            Entry("Appenzell Ausserrhoden", ["AR"]),
            Entry("Appenzell Innerrhoden", ["AI"]),
            Entry("St. Gallen", ["Sankt Gallen", "St.Gallen", "SG"]),
            Entry("Graubünden", ["Grisons", "Grigioni", "GR"]),
            Entry("Aargau", ["Argovia", "AG"]),
            Entry("Thurgau", ["TG"]),
            Entry("Tessin", ["Ticino", "TI"]),
            Entry("Waadt", ["Vaud", "VD"]),
            Entry("Wallis", ["Valais", "VS"]),
            Entry("Neuenburg", ["Neuchâtel", "NE"]),
            Entry("Genf", ["Geneva", "Genève", "GE"]),
            Entry("Jura", ["JU"]),
        ],
    ]

    /// SUBREGION tables. Cities/landscape names mapped to their state,
    /// worked TOP-DOWN from the MEASURED "Other" list (DE: 390/3221
    /// stations = 12 % in Other; the
    /// entries below cover the measured head). Pure data, extendable;
    /// ambiguous names (Berlin-Brandenburg, Romandie, "SN, ST, TH") stay
    /// DELIBERATELY in Other. Honestly other beats wrongly assigned.
    static let subregions: [String: [String: [String]]] = [
        "DE": [
            "Bayern": ["München", "Munich", "Franken", "Würzburg", "Nürnberg", "Augsburg", "Regensburg", "Oberbayern", "Allgäu", "Babaria", "Beieren", "Günzburg", "Gersthofen", "Erlenbach"],
            "Nordrhein-Westfalen": ["Köln", "Cologne", "Bochum", "Düsseldorf", "Dortmund", "Essen", "Ruhrgebiet", "Ostwestfalen", "Münster", "Aachen", "Bonn", "Wuppertal", "Bielefeld", "Sauerland", "Mönchengladbach", "Moers", "Viersen", "Witten", "Recklinghausen", "Herford", "Bad Munstereifel", "Bad Oeynhausen", "Monheim"],
            "Sachsen": ["Leipzig", "Dresden", "Chemnitz", "Saxonia", "Sachsonia", "Sassonia", "Saxon", "Ore Mountains", "Spitzkunnersdorf"],
            "Niedersachsen": ["Ostfriesland", "Hannover", "Oldenburg", "Braunschweig", "Niedersachcen", "NDS", "Bückeburg", "Fassberg"],
            "Thüringen": ["Erfurt", "Jena", "Weimar", "Thueringen", "Thunringia"],
            "Baden-Württemberg": ["Mannheim", "Konstanz", "Stuttgart", "Karlsruhe", "Freiburg", "Heidelberg", "Baden Wuertemberg", "Baden Wuerttemberg", "Bodensee", "Göppingen", "Radolfzell", "Sandhausen"],
            "Hessen": ["Frankfurt", "Kassel", "Wiesbaden", "Darmstadt", "Waldeck-Frankenberg"],
            "Sachsen-Anhalt": ["Magdeburg", "Halle"],
            "Rheinland-Pfalz": ["Mainz", "Koblenz", "Trier", "Ludwigshafen"],
            "Saarland": ["Saarbrücken", "Neunkirchen"],
            "Mecklenburg-Vorpommern": ["Rostock", "Schwerin"],
            "Schleswig-Holstein": ["Kiel", "Lübeck", "Flensburg", "Schleswig Holtstein", "Sylt"],
            "Brandenburg": ["Potsdam", "Cottbus"],
            "Bremen": ["Bremerhaven"],
        ],
        "AT": [
            "Wien": ["Vienna"],
            "Steiermark": ["Graz", "Styria"],
            "Oberösterreich": ["Linz", "Upper Austria"],
            "Niederösterreich": ["Lower Austria", "St. Pölten"],
            "Tirol": ["Innsbruck", "Tyrol"],
            "Kärnten": ["Klagenfurt", "Sankt Veit", "Carinthia"],
        ],
        "CH": [
            "Aargau": ["Aarau"],
            "Zürich": ["Winterthur"],
            "Waadt": ["Lausanne", "Canton of Vaud"],
            "Tessin": ["Lugano"],
            "Bern": ["Kanton Bern"],
        ],
    ]

    /// Nationwide pseudo-states: dropped, never pooled into "Other".
    static let nationalAliases: [String: [String]] = [
        "DE": ["Germany", "Deutschland", "bundesweit", "deutschlandweit", "national"],
        "AT": ["Austria", "Österreich", "österreichweit", "national"],
        "CH": ["Switzerland", "Schweiz", "Suisse", "Svizzera", "Svizra", "national"],
    ]

    /// Token-subsequence claim: which DISTINCT canon states match inside a
    /// composed name (word-boundary sequence, not substring. "BE" never
    /// fires inside "Berlin" because tokens compare whole words).
    static func tokenMatches(nameKey: String, aliasToCanon: [String: String]) -> Set<String> {
        let words = nameKey.split(separator: " ").map(String.init)
        guard !words.isEmpty else { return [] }
        var claims = Set<String>()
        for (alias, canon) in aliasToCanon {
            let aliasWords = alias.split(separator: " ").map(String.init)
            guard !aliasWords.isEmpty, aliasWords.count <= words.count else { continue }
            for start in 0...(words.count - aliasWords.count) {
                if Array(words[start..<(start + aliasWords.count)]) == aliasWords {
                    claims.insert(canon)
                    break
                }
            }
        }
        return claims
    }

    /// nil = no table for this country → callers use the generic curation.
    /// Canon entries keep the count-desc order of the generic path (only
    /// REPRESENTED regions appear. A zero-station tap helps nobody);
    /// "Other" always trails.
    static func curated(_ raw: [RadioBrowseEntry], countryCode: String?,
                        otherLabel: String) -> [RadioBrowseCuration.Curated]? {
        guard let code = countryCode?.uppercased(), let table = tables[code] else { return nil }
        var aliasToCanon: [String: String] = [:]
        for entry in table {
            aliasToCanon[canonKey(entry.display)] = entry.display
            for alias in entry.aliases { aliasToCanon[canonKey(alias)] = entry.display }
        }
        let national = Set((nationalAliases[code] ?? []).map(canonKey))

        // Subregion aliases fold into the exact-match map (pure data join).
        for (canonName, places) in subregions[code] ?? [:] {
            for place in places { aliasToCanon[canonKey(place)] = canonName }
        }

        var byCanon: [String: [RadioBrowseEntry]] = [:]
        var other: [RadioBrowseEntry] = []
        for entry in raw {
            let trimmed = entry.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let key = canonKey(trimmed)
            if national.contains(key) { continue }
            if let canon = aliasToCanon[key] {
                byCanon[canon, default: []].append(entry)
                continue
            }
            // Boil down COMPOSED names ("Deutschland und NRW", "Bayern,
            // München, AAC", "Hessen (Kassel)") get a token-subsequence
            // match against every alias; EXACTLY ONE state may claim the entry
            // (multi-matches like "SN, ST, TH" stay honestly in Other),
            // national-only tokens drop.
            let claimed = tokenMatches(nameKey: key, aliasToCanon: aliasToCanon)
            if claimed.count == 1, let canon = claimed.first {
                byCanon[canon, default: []].append(entry)
            } else if claimed.isEmpty, national.contains(where: { key.contains($0) }),
                      claimed.isEmpty {
                continue   // "Deutschland (Germany)" class → national, drops
            } else {
                other.append(entry)
            }
        }

        var out: [RadioBrowseCuration.Curated] = table.compactMap { entry in
            guard let variants = byCanon[entry.display] else { return nil }
            var seen = Set<String>()
            return RadioBrowseCuration.Curated(
                display: entry.display,
                queryNames: variants.map(\.name).filter { seen.insert($0).inserted },
                stationCount: variants.reduce(0) { $0 + $1.stationCount })
        }
        out.sort { a, b in
            a.stationCount == b.stationCount
                ? a.display.localizedCaseInsensitiveCompare(b.display) == .orderedAscending
                : a.stationCount > b.stationCount
        }
        if !other.isEmpty {
            var seen = Set<String>()
            out.append(RadioBrowseCuration.Curated(
                display: otherLabel,
                queryNames: other.map(\.name).filter { seen.insert($0).inserted },
                stationCount: other.reduce(0) { $0 + $1.stationCount }))
        }
        return out
    }
}

/// The favicon QUALITY GATE. Radio-Browser favicons are
/// notoriously missing, tiny, or broken. A favicon is used only when it
/// actually decoded AND its shortest side is big enough; everything else
/// falls back to ONE placeholder design everywhere (deterministic station
/// gradient + initials). Pure and tested.
nonisolated enum RadioFaviconGate {
    /// Below this shortest side a favicon becomes a stretched stamp.
    static let minSide = 64
    /// The CHAIN's stage-2 icons are apple-touch-icons.
    /// Square brand marks in Apple's standard sizes (57/60/72/76/114/120…).
    /// The 64 gate exists against favicon MUSH; it also threw away four
    /// perfectly good 57 px brand icons in the audit set. A touch icon is a
    /// declared logo, not a scraped favicon, so it gets its own floor.
    static let touchIconMinSide = 48

    static func acceptableTouchIcon(pixelWidth: Int, pixelHeight: Int) -> Bool {
        min(pixelWidth, pixelHeight) >= touchIconMinSide
    }

    /// The gate takes the SURFACE's target size. A 48-px favicon is
    /// mush on a hero and perfectly sharp in a 32-pt search row. The
    /// absolute 64 answered both the same way. `targetSide` is the rendered
    /// point size; the requirement is what that surface actually needs at
    /// screen scale (capped by the strict default, so no surface can ask for
    /// MORE than the general rule). nil = strict default, unchanged.
    static func acceptable(pixelWidth: Int, pixelHeight: Int,
                           targetSide: CGFloat? = nil) -> Bool {
        min(pixelWidth, pixelHeight) >= required(targetSide: targetSide)
    }

    /// Pure and testable: what a surface needs in pixels.
    static func required(targetSide: CGFloat?, scale: CGFloat = 3) -> Int {
        guard let targetSide, targetSide > 0 else { return minSide }
        return min(minSide, Int((targetSide * scale).rounded()))
    }

    /// Station initials for the placeholder: first character of the first
    /// two words that start alphanumerically ("Radio Paradise" → "RP",
    /// "104.6 RTL" → "1R"). Nothing usable → nil (callers show the glyph).
    static func initials(for name: String) -> String? {
        let words = name.split(whereSeparator: { $0.isWhitespace || $0 == "-" || $0 == "/" })
        let letters = words.compactMap { word -> Character? in
            word.first(where: { $0.isLetter || $0.isNumber })
        }
        guard !letters.isEmpty else { return nil }
        return String(letters.prefix(2)).uppercased()
    }
}

nonisolated enum RadioCountryCascade {
    /// The NATIONAL row's country. Its own explicit choice wins;
    /// without one it follows the shared cascade. Which IS the migration:
    /// whoever never decouples sees exactly today's behaviour, and there is
    /// no jump on first launch because nothing is written eagerly.
    static func nationalCode(explicitNational: String?, shared: String?) -> String? {
        if let explicitNational, !explicitNational.isEmpty { return explicitNational }
        return shared
    }

    static func effectiveCode(explicit: String?, regionImplied: String?, locale: String?) -> String? {
        if let explicit, !explicit.isEmpty { return explicit }
        if let regionImplied, !regionImplied.isEmpty { return regionImplied }
        if let locale, !locale.isEmpty { return locale }
        return nil
    }
}

/// The catalog browse layer for the radio tab. A CURATED genre
/// set (the raw tag cloud is too noisy) plus the pure offline/section-gating
/// rules. Extendable: add rows to `genres`.
nonisolated enum RadioCatalog {
    static let genres: [RadioGenre] = [
        RadioGenre(tag: "news", systemImage: "newspaper", title: String(localized: "News")),
        RadioGenre(tag: "music", systemImage: "music.note", title: String(localized: "Music")),
        RadioGenre(tag: "pop", systemImage: "music.mic", title: String(localized: "Pop")),
        RadioGenre(tag: "rock", systemImage: "guitars", title: String(localized: "Rock")),
        RadioGenre(tag: "classical", systemImage: "pianokeys", title: String(localized: "Classical")),
        RadioGenre(tag: "jazz", systemImage: "music.quarternote.3", title: String(localized: "Jazz")),
        RadioGenre(tag: "electronic", systemImage: "waveform", title: String(localized: "Electronic")),
        RadioGenre(tag: "talk", systemImage: "bubble.left.and.bubble.right", title: String(localized: "Talk")),
        RadioGenre(tag: "sport", systemImage: "sportscourt", title: String(localized: "Sport")),
        RadioGenre(tag: "culture", systemImage: "theatermasks", title: String(localized: "Culture")),
    ]

    /// The eyebrow over a station name, or nothing.
    ///
    /// The raw first tag stood there: English on a German device, and
    /// mixed in KIND ("MUSIC" and "FOLK" are genres, "ARD" is a network,
    /// "MOSCOW" a place). In a row called "Nachrichten" it read "MUSIC",
    /// which says something actively wrong. So only tags we can NAME in
    /// the user's language pass, and everything else stays silent: a
    /// station name alone is honest, a wrong category is not.
    static func eyebrow(forTags tags: [String]) -> String? {
        for raw in tags {
            let key = raw.trimmingCharacters(in: .whitespaces).lowercased()
            if let genre = genres.first(where: { $0.tag == key }) { return genre.title }
        }
        return nil
    }

    /// The device region as an uppercase ISO country code for the "From your
    /// region" section. Nil when the locale has no region (→ section hidden).
    static func deviceRegionCode(locale: Locale = .current) -> String? {
        guard let cc = locale.region?.identifier, !cc.isEmpty else { return nil }
        return cc.uppercased()
    }

    // Section-visibility gates (pure): the catalog sections need the network,
    // so offline they vanish and the tab falls back to favorites/recents.
    static func showsPopular(isConnected: Bool, popular: [RadioStation]) -> Bool {
        isConnected && !popular.isEmpty
    }

    static func showsRegion(isConnected: Bool, regionCode: String?, regional: [RadioStation]) -> Bool {
        isConnected && (regionCode?.isEmpty == false) && !regional.isEmpty
    }

    static func showsGenres(isConnected: Bool) -> Bool {
        isConnected
    }
}
