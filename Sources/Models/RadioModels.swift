import Foundation

/// F1: internet radio — the Foundation-only core (MaerCore rule: no UI
/// imports; Android groundwork). A station is LIVE audio: no duration, no
/// position, no download — the capability flags stay honest (see
/// RadioProvider).
nonisolated struct RadioStation: Codable, Identifiable, Equatable, Sendable {
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
    /// name-based collapse (per-variant selection comes later).
    var bitrate: Int? = nil
    var codec: String? = nil

    var isManual: Bool { id.hasPrefix("radio:manual:") }
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
        var order: [String] = []
        var best: [String: RadioStation] = [:]
        for station in stations {
            let key = variantKey(for: station)
            if let existing = best[key] {
                if prefers(station, over: existing) { best[key] = station }
            } else {
                best[key] = station
                order.append(key)
            }
        }
        return order.compactMap { best[$0] }
    }

    private static func variantKey(for station: RadioStation) -> String {
        "\(normalizedStationName(station.name))|\(station.countryCode?.lowercased() ?? "")"
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
}
