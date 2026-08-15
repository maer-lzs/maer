// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation

/// F1: internet radio — the Foundation-only core (MaerCore rule: no UI
/// imports; Android groundwork). A station is LIVE audio: no duration, no
/// position, no download — the capability flags stay honest (see
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
    /// Y57: stream quality — drives which codec/bitrate variant survives the
    /// name-based collapse.
    var bitrate: Int? = nil
    var codec: String? = nil
    /// 71b277f: RB vote mass — the regional socket/floor decides on it.
    var votes: Int? = nil
    /// Teil 1: the sibling codec/bitrate variants of this station (the collapse
    /// keeps the best as default and attaches ALL variants here, self included).
    /// Optional so already-persisted stations decode unchanged (no key → nil);
    /// nested variants are always flattened to nil (no recursion).
    var variants: [RadioStation]? = nil

    var isManual: Bool { id.hasPrefix("radio:manual:") }

    /// The variant list (self included) or empty when this station has no
    /// alternatives — the picker only appears for two or more.
    var variantList: [RadioStation] { variants ?? [] }

    /// Teil 1: human label for the variant picker — "128 kbps · MP3", one part,
    /// or a generic fallback. Foundation-only (like the curated genre titles).
    var qualityLabel: String {
        var parts: [String] = []
        if let bitrate, bitrate > 0 { parts.append("\(bitrate) kbps") }
        if let codec, !codec.isEmpty { parts.append(codec.uppercased()) }
        return parts.isEmpty ? String(localized: "Stream") : parts.joined(separator: " · ")
    }

    // Identity is the namespaced id — the attached variants/quality never change
    // WHICH station this is, and id-based identity keeps store/dedupe lookups and
    // value-based navigation stable regardless of the transient variant payload.
    static func == (l: RadioStation, r: RadioStation) -> Bool { l.id == r.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

/// Radio Browser API station payload (subset). The API is an OPEN catalog —
/// no key; served by volunteer MIRRORS, so the same station can arrive from
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

    enum CodingKeys: String, CodingKey {
        case stationuuid, name, url, favicon, homepage, countrycode, tags, bitrate, codec, votes
        case urlResolved = "url_resolved"
    }
}

nonisolated enum RadioMapping {
    /// Map + de-dupe (mirror double-serves by stationuuid) + drop unusable
    /// entries (empty name/url), then fold codec/bitrate variants (Y57). Order
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
                id: "radio:rb:\(s.stationuuid)",
                name: name,
                streamURL: stream,
                faviconURL: s.favicon?.isEmpty == false ? s.favicon : nil,
                homepage: s.homepage?.isEmpty == false ? s.homepage : nil,
                countryCode: s.countrycode?.isEmpty == false ? s.countrycode : nil,
                tags: (s.tags ?? "").split(separator: ",").map(String.init).filter { !$0.isEmpty },
                bitrate: (s.bitrate ?? 0) > 0 ? s.bitrate : nil,
                codec: s.codec?.isEmpty == false ? s.codec : nil,
                votes: s.votes))
        }
        return collapseVariants(result)
    }

    /// Y57: fold codec/bitrate VARIANTS of the same station (same normalized
    /// name + country) into ONE hit. The variants carry distinct stationuuids,
    /// so they pass the uuid de-dupe legitimately; here they collapse to the
    /// highest-bitrate variant (tie-break: prefer MP3), so the default plays the
    /// best stream. Per-variant selection comes later. First-appearance order
    /// (i.e. the highest-voted variant's position) is preserved.
    static func collapseVariants(_ stations: [RadioStation]) -> [RadioStation] {
        // Y59: greedy grouping instead of a plain name|country key. Radio
        // Browser reports the SAME station's country inconsistently ("DE" on one
        // variant, empty on the next), which split e.g. Deutschlandfunk into two
        // buckets. Country is now only a SEPARATOR when two variants carry two
        // DIFFERENT non-empty codes; empty/nil is compatible with anything of the
        // same name. Each bucket tracks its first non-empty code as the effective
        // country, so an empty-country variant can't glue two real countries
        // together. Not a plain equivalence (compatibility isn't transitive), so
        // it can't be a hash key — a linear scan over the (≤40) buckets.
        var buckets: [(name: String, country: String?, members: [RadioStation])] = []
        for station in stations {
            let name = normalizedStationName(station.name)
            let code = normalizedCountry(station.countryCode)
            var flat = station; flat.variants = nil   // never nest variants
            if let idx = buckets.firstIndex(where: {
                $0.name == name && countryCompatible(bucket: $0.country, station: code)
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

    /// Teil 1 (pure): a STABLE key for a station's variant selection — survives
    /// catalog rotation (a different variant winning the collapse) because it
    /// keys on the normalized name + country, not the volatile stationuuid.
    static func variantKey(for station: RadioStation) -> String {
        normalizedStationName(station.name) + "|" + (normalizedCountry(station.countryCode) ?? "")
    }

    /// Teil 1 (pure): resolve the stream to play — the user's persisted variant
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
    /// are non-empty AND differ — so a missing code never separates.
    private static func countryCompatible(bucket: String?, station: String?) -> Bool {
        guard let station, let bucket else { return true }
        return bucket == station
    }

    /// 6b3a35d (4): DISPLAY name — station names carry pipe-separated junk
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
        // ("Deutschlandfunk AAC 192k") — strip trailing decorations only;
        // the ORIGINAL name stays in detail/search.
        let tailJunk = "((\\b(mp3|aac\\+?|he-?aac|opus|ogg|vorbis|flac|wma)\\b|\\b\\d{2,3}\\s?k(bps)?\\b|\\bstream\\s?\\d+\\b)[\\s.]*)+$"
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
        for pattern in ["\\b(mp3|aac\\+?|he-?aac|opus|ogg|vorbis|flac|wma)\\b",
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
        // e4bd910 Nachtrag (FINAL): codec preference AAC > MP3.
        let aAAC = a.codec?.lowercased().contains("aac") == true
        let bAAC = b.codec?.lowercased().contains("aac") == true
        return aAAC && !bAAC
    }

    /// e4bd910 Sender-Dedupe: RB serves the same station multiply (stream
    /// variants, stale twins). Identity = display-normalized name PLUS the
    /// homepage/stream DOMAIN as the second key — a same-named FOREIGN
    /// station (different domain) never folds in (the Rock-Antenne-Italy
    /// class); real program siblings (1LIVE vs 1LIVE Dance Hits) differ by
    /// name and never fold either. The best member wins (bitrate, AAC>MP3);
    /// the losers ride as `variants` so the detail page offers them as
    /// further streams instead of throwing them away.
    /// a4e747e (pure): in a list fetched WITH a country filter, an entry
    /// whose country code belongs to a DIFFERENT country is dropped. Empty
    /// codes stay — Radio Browser reports countries patchily, and in this
    /// context "empty" means "belongs to the queried country", not "fits
    /// everything" (the Y59 merge reads it the second way, which is right
    /// without a country context and wrong inside one).
    static func keepingCountry(_ countryCode: String, in stations: [RadioStation]) -> [RadioStation] {
        let wanted = countryCode.trimmingCharacters(in: .whitespaces).uppercased()
        guard !wanted.isEmpty else { return stations }
        return stations.filter { station in
            let code = (station.countryCode ?? "").trimmingCharacters(in: .whitespaces).uppercased()
            return code.isEmpty || code == wanted
        }
    }

    static func dedupeForDisplay(_ stations: [RadioStation]) -> [RadioStation] {
        var buckets: [String: RadioStation] = [:]
        var order: [String] = []
        for station in stations {
            var flat = station
            let key = displayIdentityKey(station)
            if var existing = buckets[key] {
                var variants = existing.variants ?? []
                if prefers(flat, over: existing) {
                    let loser = existing
                    flat.variants = variants + [strippedVariant(loser)] + (loser.variants ?? [])
                    buckets[key] = flat
                } else {
                    variants.append(strippedVariant(flat))
                    existing.variants = variants
                    buckets[key] = existing
                }
            } else {
                flat.variants = flat.variants ?? nil
                buckets[key] = flat
                order.append(key)
            }
        }
        return order.compactMap { buckets[$0] }
    }

    private static func strippedVariant(_ station: RadioStation) -> RadioStation {
        var flat = station
        flat.variants = nil   // never nest
        return flat
    }

    /// Identity key: folded display name + comparable domain (homepage
    /// preferred — CDN stream hosts differ between real variants).
    static func displayIdentityKey(_ station: RadioStation) -> String {
        let name = RadioBrowseCuration.mergeKey(displayName(station.name))
        let domainSource = station.homepage?.isEmpty == false ? station.homepage! : station.streamURL
        return name + "|" + PodcastSubscriptions.feedHost(domainSource)
    }

    /// A user-entered stream (name + URL) — nil when the URL is unusable.
    static func manualStation(name: String, urlString: String,
                              id: String = "radio:manual:\(UUID().uuidString)") -> RadioStation? {
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        let trimmedURL = urlString.trimmingCharacters(in: .whitespaces)
        guard !trimmedName.isEmpty, let url = URL(string: trimmedURL),
              url.scheme?.hasPrefix("http") == true else { return nil }
        return RadioStation(id: id, name: trimmedName, streamURL: trimmedURL)
    }
}

/// F2: ICY/shoutcast in-stream metadata — the timed-metadata frame usually
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

/// F4: local station lists — favorites and manual stations (persisted), plus
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

    private static func save(_ stations: [RadioStation], _ key: String, defaults: UserDefaults) {
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

    static func toggleFavorite(_ station: RadioStation, defaults: UserDefaults = .standard) {
        var list = favorites(defaults: defaults)
        if let idx = list.firstIndex(where: { $0.id == station.id }) {
            list.remove(at: idx)
        } else {
            list.append(station)
        }
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

    static func removeManual(_ id: String, defaults: UserDefaults = .standard) {
        var list = manualStations(defaults: defaults)
        list.removeAll { $0.id == id }
        save(list, manualKey, defaults: defaults)
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
        // P14: the MRU ORDER alone cannot be merged with another class — a
        // joint "recently played" row needs a comparable TIME. Kept beside
        // the ring (not inside the station), so nothing about the station
        // model changes.
        var stamps = recentTimes(defaults: defaults)
        stamps[station.id] = Date().timeIntervalSince1970
        let live = Set(recents(defaults: defaults).map(\.id))
        defaults.set(stamps.filter { live.contains($0.key) }, forKey: recentTimesKey)
    }

    private static let recentTimesKey = "radioRecentTimes"

    /// station id → last played (seconds). Missing for stations heard before
    /// this existed — the caller ranks those after the dated ones instead of
    /// inventing a time.
    static func recentTimes(defaults: UserDefaults = .standard) -> [String: Double] {
        (defaults.dictionary(forKey: recentTimesKey) as? [String: Double]) ?? [:]
    }

    /// Resolve any known station by id (favorites, manual, recents).
    static func station(forId id: String, defaults: UserDefaults = .standard) -> RadioStation? {
        (favorites(defaults: defaults) + manualStations(defaults: defaults) + recents(defaults: defaults))
            .first { $0.id == id }
    }

    // MARK: - 26b2c13: last composed discovery rows (cold-start frame 1)

    static let discoveryCacheKey = "radioDiscoveryCache"

    nonisolated struct DiscoveryCache: Codable {
        var popular: [RadioStation]
        var regional: [RadioStation]
        /// The rotation day the rows were composed for — a NEW day recomputes
        /// (showing this stale state until the fresh one lands, never blank).
        var day: Int
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

    /// Stations ranked by play frequency (desc), capped — the "Most Played" row.
    static func mostPlayed(limit: Int = 8, defaults: UserDefaults = .standard) -> [RadioStation] {
        RadioRanking.mostPlayed(stations: load(mostPlayedKey, defaults: defaults),
                                counts: playCounts(defaults: defaults), limit: limit)
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
    static func setSelectedVariant(_ streamURL: String, for station: RadioStation,
                                   defaults: UserDefaults = .standard) {
        var dict = variantSelections(defaults: defaults)
        let key = RadioMapping.variantKey(for: station)
        if streamURL == station.streamURL { dict[key] = nil } else { dict[key] = streamURL }
        defaults.set(dict, forKey: variantSelectionKey)
    }
}

/// Home "Radio" section gating (pure): the section renders ONLY when the radio
/// source is active AND there is something to show — never an empty placeholder.
nonisolated enum RadioHomePresentation {
    static func showsSection(radioActive: Bool, recentsCount: Int) -> Bool {
        radioActive && recentsCount > 0
    }
}


/// Teil 3 (pure, tested): rank stations by play frequency. Positive counts only,
/// descending; ties keep the later-stored (more-recently-played) station first;
/// capped. Foundation-only (MaerCore rule) — no store, no UI.
nonisolated enum RadioRanking {
    static func mostPlayed(stations: [RadioStation], counts: [String: Int], limit: Int) -> [RadioStation] {
        guard limit > 0 else { return [] }
        return stations.enumerated()
            .filter { (counts[$0.element.id] ?? 0) > 0 }
            .sorted { a, b in
                let ca = counts[a.element.id] ?? 0, cb = counts[b.element.id] ?? 0
                if ca != cb { return ca > cb }
                return a.offset > b.offset   // tie → more recently stored wins
            }
            .prefix(limit)
            .map(\.element)
    }
}

/// F4-discovery: one curated genre — a Radio Browser tag with a display name
/// and an SF Symbol. Foundation-only (MaerCore rule): the glyph is just a name
/// string, the view renders it.
nonisolated struct RadioGenre: Identifiable, Equatable, Sendable {
    let tag: String          // exact Radio Browser tag (bytagexact)
    let systemImage: String
    let title: String
    var id: String { tag }
}

/// Radio-Picker-Kuratierung (b942da6): one raw name+stationcount entry of the
/// Radio Browser `states`/`countries` lists (community data — variants,
/// junk, cities next to real regions).
nonisolated struct RadioBrowseEntry: Equatable, Sendable {
    let name: String
    let stationCount: Int
}

/// Pure curation of the raw Radio Browser region/country lists (tested with
/// the real Swiss fixture). Rules — deliberately COUNTRY-AGNOSTIC, no
/// hardcoded canton list:
/// 1. Noise filter: empty/whitespace, purely numeric names, and entries whose
///    MERGED station count stays below the threshold are dropped.
/// 2. Variant merge: case- and diacritic-insensitive (and whitespace-trimmed)
///    dedupe — "Zürich"/"Zurich"/" Zürich" collapse; the variant with the
///    most stations names the entry, the by-state query then runs against
///    ALL merged raw names (otherwise the other spelling's stations vanish).
/// 3. Sort: merged station count descending (most relevant region first),
///    ties alphabetically.
nonisolated enum RadioBrowseCuration {
    struct Curated: Equatable, Identifiable, Sendable {
        /// Display name (the variant with the most stations).
        let display: String
        /// ALL raw names of the merged variants — every one is queried.
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
            // Keep the RAW name — `bystateexact` matches byte-exactly, a
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

    /// Picker search filter (pure): case-/diacritic-insensitive substring —
    /// free text without a hit selects NOTHING (choice stays bound to
    /// existing entries).
    static func filtered(_ entries: [Curated], query: String) -> [Curated] {
        let q = mergeKey(query)
        guard !q.isEmpty else { return entries }
        return entries.filter { mergeKey($0.display).contains(q) }
    }
}

/// b1ab99d point 3: which country feeds "Popular in …" and the region list.
/// USER CHOICE BEATS GUESSING — pure cascade: explicitly chosen country →
/// country implied by the chosen region → locale country. No location access.
/// e4bd910 Nachtrag FINAL: "Beliebt in …" mit Sockel + Tages-Rotation —
/// the eternal votes list never changed. Pool = top votes + top clicktrend
/// (deduped); seats 1–3 = the CURRENT clicktrend top (the socket); the rest
/// drawn weighted with a DATE-seeded RNG (stable within the day — calm-gate
/// spirit — freshly mixed daily). Pure + tested; same mechanic for the
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

    /// 71b277f (Screenshot-entschieden): on STATE level clicktrend is noise-
    /// dominated — a webradio's mini click spike beats WDR 2. The regional
    /// socket therefore sits on VOTES (stable mass); clicktrend only joins
    /// the draw pool when it clears a minimum-votes floor. National keeps
    /// the clicktrend socket (proven correct on the device).
    enum SocketSource { case clicktrend, votes }

    /// 19a8b4c: minimum seats the VOTES fill keeps even when the core could
    /// fill the whole row — webradios stay discoverable, they only leave the
    /// top positions.
    static let fillMinimum = 4

    /// 19a8b4c: core-first composition — the first-hand core (published rank
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
        let coreKeys = Set(core.map { RadioMapping.displayIdentityKey($0) })
        let fill = compose(
            votes: votes.filter { !coreKeys.contains(RadioMapping.displayIdentityKey($0)) },
            clicktrend: clicktrend.filter { !coreKeys.contains(RadioMapping.displayIdentityKey($0)) },
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
        for (list, offset) in [(clicktrend, 0), (votes, 0)] {
            for (index, station) in list.enumerated() {
                let key = RadioMapping.displayIdentityKey(station)
                let r = index + offset
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

/// cd5cc4a (2): canonical region tables for the CORE countries — DE/AT
/// Bundesländer, CH Kantone. This deliberately overrides the "no country
/// lists" rule: raw Radio-Browser state names (any language, abbreviation,
/// or typo variant) map onto ONE canon entry via aliases, the by-state
/// query then runs against ALL mapped raw names (existing merge mechanic).
/// Unmapped names pool into ONE trailing "Other" entry; nationwide
/// pseudo-states DROP (the "Popular in <country>" section carries them).
/// Countries without a table fall back to the generic curation. Pure data —
/// extending a table is data entry, never new code.
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

    /// e4bd910/sonstige-eindampfen: SUBREGION tables — cities/landscape
    /// names mapped to their state, worked TOP-DOWN from the MEASURED
    /// "Other" list (DE 03.08.: 390/3221 stations = 12 % in Other; the
    /// entries below cover the measured head). Pure data, extendable;
    /// ambiguous names (Berlin-Brandenburg, Romandie, "SN, ST, TH") stay
    /// DELIBERATELY in Other — honestly other beats wrongly assigned.
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
    /// composed name (word-boundary sequence, not substring — "BE" never
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
    /// REPRESENTED regions appear — a zero-station tap helps nobody);
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
            // eindampfen: COMPOSED names ("Deutschland und NRW", "Bayern,
            // München, AAC", "Hessen (Kassel)") — token-subsequence match
            // against every alias; EXACTLY ONE state may claim the entry
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

/// cd5cc4a (1): the favicon QUALITY GATE — Radio-Browser favicons are
/// notoriously missing, tiny, or broken. A favicon is used only when it
/// actually decoded AND its shortest side is big enough; everything else
/// falls back to ONE placeholder design everywhere (deterministic station
/// gradient + initials). Pure and tested.
nonisolated enum RadioFaviconGate {
    /// Below this shortest side a favicon becomes a stretched stamp.
    static let minSide = 64

    static func acceptable(pixelWidth: Int, pixelHeight: Int) -> Bool {
        min(pixelWidth, pixelHeight) >= minSide
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
    /// P12: the NATIONAL row's country. Its own explicit choice wins;
    /// without one it follows the shared cascade — which IS the migration:
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

/// F4-discovery: the catalog browse layer for the radio tab — a CURATED genre
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

    /// The device region as an uppercase ISO country code for the "From your
    /// region" section — nil when the locale has no region (→ section hidden).
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
