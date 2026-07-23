// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later

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

    enum CodingKeys: String, CodingKey {
        case stationuuid, name, url, favicon, homepage, countrycode, tags, bitrate, codec
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
                codec: s.codec?.isEmpty == false ? s.codec : nil))
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
        // Equal/unknown bitrate → prefer an MP3 stream (widest compatibility).
        let aMP3 = a.codec?.lowercased().contains("mp3") == true
        let bMP3 = b.codec?.lowercased().contains("mp3") == true
        return aMP3 && !bMP3
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
    }

    /// Resolve any known station by id (favorites, manual, recents).
    static func station(forId id: String, defaults: UserDefaults = .standard) -> RadioStation? {
        (favorites(defaults: defaults) + manualStations(defaults: defaults) + recents(defaults: defaults))
            .first { $0.id == id }
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
