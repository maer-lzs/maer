// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later

#if canImport(Testing)
import Testing
import Foundation
@testable import ABSPlayer

/// F5: the pure radio core — station mapping (mirror de-dupe), manual-station
/// validation, ICY parsing, the store round-trip and the queue veto (F3).
struct RadioModelsTests {
    private func raw(_ uuid: String, name: String = "Station", url: String = "https://s.example/a",
                     resolved: String? = nil, country: String? = nil,
                     bitrate: Int? = nil, codec: String? = nil) -> RadioBrowserStation {
        RadioBrowserStation(stationuuid: uuid, name: name, url: url, urlResolved: resolved,
                            favicon: nil, homepage: nil, countrycode: country, tags: "jazz,news",
                            bitrate: bitrate, codec: codec)
    }

    @Test("mapping de-dupes by stationuuid, prefers url_resolved, drops unusable")
    func mapping() {
        let stations = RadioMapping.stations(from: [
            raw("a", name: "One", url: "https://s.example/plain", resolved: "https://s.example/resolved"),
            raw("a", name: "One again"),                       // mirror double-serve
            raw("b", name: "  "),                              // empty name → dropped
            raw("c", name: "Three", url: " "),                 // empty url → dropped
            raw("d", name: "Four"),
        ])
        #expect(stations.map(\.id) == ["radio:rb:a", "radio:rb:d"])
        #expect(stations.first?.streamURL == "https://s.example/resolved")
        #expect(stations.first?.tags == ["jazz", "news"])
    }

    @Test("Y57: codec/bitrate variants of one station fold to the best single hit")
    func collapsesVariants() {
        // Three variants of the same station (distinct uuids, different urls) —
        // highest bitrate wins; a genuinely different station stays.
        let stations = RadioMapping.stations(from: [
            raw("v1", name: "Deutschlandfunk | DLF | MP3 128k", url: "https://s/1", country: "DE", bitrate: 128, codec: "MP3"),
            raw("v2", name: "Deutschlandfunk | DLF | OPUS 24k", url: "https://s/2", country: "DE", bitrate: 24, codec: "OPUS"),
            raw("v3", name: "Deutschlandfunk | DLF | AAC 48k", url: "https://s/3", country: "DE", bitrate: 48, codec: "AAC"),
            raw("other", name: "Jazz Radio", url: "https://s/j", country: "DE", bitrate: 128, codec: "MP3"),
        ])
        #expect(stations.map(\.id) == ["radio:rb:v1", "radio:rb:other"])
        #expect(stations.first?.bitrate == 128)
    }

    @Test("Y59: inconsistent country codes on one station still collapse to one")
    func collapseInconsistentCountry() {
        // Radio Browser reports the SAME station's country as "DE", empty and
        // "de " across its codec variants — they must still fold to ONE.
        let folded = RadioMapping.stations(from: [
            raw("d1", name: "Deutschlandfunk | DLF | MP3 128k", url: "https://s/1", country: "DE"),
            raw("d2", name: "Deutschlandfunk | DLF | AAC 48k", url: "https://s/2", country: ""),
            raw("d3", name: "Deutschlandfunk | DLF | OPUS 24k", url: "https://s/3", country: "de "),
        ])
        #expect(folded.count == 1)

        // But two genuinely different same-named stations in different countries
        // (both codes present, different) stay apart — no mis-fusion.
        let byCountry = RadioMapping.collapseVariants([
            RadioStation(id: "radio:rb:de", name: "Radio X", streamURL: "https://s/de", countryCode: "DE"),
            RadioStation(id: "radio:rb:fr", name: "Radio X", streamURL: "https://s/fr", countryCode: "FR"),
        ])
        #expect(byCountry.count == 2)

        // An empty-country variant must not glue two real countries together.
        let withEmpty = RadioMapping.collapseVariants([
            RadioStation(id: "radio:rb:x", name: "Radio X", streamURL: "https://s/x", countryCode: nil),
            RadioStation(id: "radio:rb:de", name: "Radio X", streamURL: "https://s/de", countryCode: "DE"),
            RadioStation(id: "radio:rb:fr", name: "Radio X", streamURL: "https://s/fr", countryCode: "FR"),
        ])
        #expect(withEmpty.count == 2)
    }

    @Test("Y57: equal bitrate prefers MP3; different country is not merged")
    func collapseTieBreakAndCountry() {
        let tie = RadioMapping.collapseVariants([
            RadioStation(id: "radio:rb:a", name: "Radio X AAC", streamURL: "https://s/a", countryCode: "DE", bitrate: 128, codec: "AAC"),
            RadioStation(id: "radio:rb:b", name: "Radio X MP3", streamURL: "https://s/b", countryCode: "DE", bitrate: 128, codec: "MP3"),
        ])
        #expect(tie.map(\.id) == ["radio:rb:b"])   // MP3 wins the tie

        let byCountry = RadioMapping.collapseVariants([
            RadioStation(id: "radio:rb:de", name: "Radio X", streamURL: "https://s/de", countryCode: "DE"),
            RadioStation(id: "radio:rb:fr", name: "Radio X", streamURL: "https://s/fr", countryCode: "FR"),
        ])
        #expect(byCountry.count == 2)   // same name, different country → kept apart
    }

    @Test("manual stations validate name and http(s) URL")
    func manualValidation() {
        #expect(RadioMapping.manualStation(name: "Mine", urlString: "https://a.example/s") != nil)
        #expect(RadioMapping.manualStation(name: "", urlString: "https://a.example/s") == nil)
        #expect(RadioMapping.manualStation(name: "X", urlString: "ftp://a.example/s") == nil)
        #expect(RadioMapping.manualStation(name: "X", urlString: "not a url at all …") == nil)
        #expect(RadioMapping.manualStation(name: "X", urlString: "https://ok.example")?.isManual == true)
    }

    @Test("ICY StreamTitle splits artist/title on the conventional separator")
    func icyParsing() {
        let both = ICYMetadata.parse(streamTitle: "Miles Davis - So What")
        #expect(both?.title == "So What")
        #expect(both?.artist == "Miles Davis")
        // Extra separators stay in the TITLE (artist is the first segment).
        let nested = ICYMetadata.parse(streamTitle: "A - B - C")
        #expect(nested?.title == "B - C")
        #expect(nested?.artist == "A")
        let plain = ICYMetadata.parse(streamTitle: "Nachrichten")
        #expect(plain?.title == "Nachrichten")
        #expect(plain?.artist == nil)
        #expect(ICYMetadata.parse(streamTitle: "   ") == nil)
    }

    @Test("store round-trips favorites, manual list and the capped recents ring")
    func storeRoundTrip() {
        let name = "radio-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let a = RadioStation(id: "radio:manual:a", name: "A", streamURL: "https://a.example/s")
        let b = RadioStation(id: "radio:rb:b", name: "B", streamURL: "https://b.example/s")

        RadioStore.toggleFavorite(a, defaults: defaults)
        #expect(RadioStore.isFavorite("radio:manual:a", defaults: defaults))
        RadioStore.toggleFavorite(a, defaults: defaults)
        #expect(!RadioStore.isFavorite("radio:manual:a", defaults: defaults))

        RadioStore.addManual(a, defaults: defaults)
        #expect(RadioStore.manualStations(defaults: defaults).map(\.id) == ["radio:manual:a"])
        RadioStore.removeManual("radio:manual:a", defaults: defaults)
        #expect(RadioStore.manualStations(defaults: defaults).isEmpty)

        for i in 0..<(RadioStore.recentsCap + 2) {
            RadioStore.recordRecent(RadioStation(id: "radio:rb:\(i)", name: "S\(i)",
                                                 streamURL: "https://r.example/\(i)"), defaults: defaults)
        }
        RadioStore.recordRecent(b, defaults: defaults)
        let recents = RadioStore.recents(defaults: defaults)
        #expect(recents.count == RadioStore.recentsCap)
        #expect(recents.first?.id == "radio:rb:b")
    }

    @Test("Teil 3: RadioRanking orders by play count, drops zero, breaks ties by recency, caps")
    func mostPlayedRanking() {
        func s(_ id: String) -> RadioStation { RadioStation(id: "radio:rb:\(id)", name: id, streamURL: "https://s/\(id)") }
        // Store order (append = more recent): a, b, c, d. Counts as noted.
        let stations = [s("a"), s("b"), s("c"), s("d")]
        let counts = ["radio:rb:a": 3, "radio:rb:b": 1, "radio:rb:c": 5, "radio:rb:d": 0]
        // c(5) > a(3) > b(1); d has zero plays → dropped.
        #expect(RadioRanking.mostPlayed(stations: stations, counts: counts, limit: 8).map(\.name) == ["c", "a", "b"])
        // Cap.
        #expect(RadioRanking.mostPlayed(stations: stations, counts: counts, limit: 2).map(\.name) == ["c", "a"])
        #expect(RadioRanking.mostPlayed(stations: stations, counts: counts, limit: 0).isEmpty)
        // Tie on count → later-stored (more recent) first: b stored after a.
        let tie = RadioRanking.mostPlayed(stations: [s("a"), s("b")],
                                          counts: ["radio:rb:a": 2, "radio:rb:b": 2], limit: 8)
        #expect(tie.map(\.name) == ["b", "a"])
    }

    @Test("Teil 3: recordPlay counts plays; mostPlayed reflects frequency and persists")
    func recordPlayStore() {
        let name = "radio-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        func s(_ id: String) -> RadioStation { RadioStation(id: "radio:rb:\(id)", name: id.uppercased(), streamURL: "https://s/\(id)") }
        for _ in 0..<3 { RadioStore.recordPlay(s("a"), defaults: defaults) }
        RadioStore.recordPlay(s("b"), defaults: defaults)
        for _ in 0..<2 { RadioStore.recordPlay(s("c"), defaults: defaults) }
        #expect(RadioStore.playCounts(defaults: defaults)["radio:rb:a"] == 3)
        #expect(RadioStore.mostPlayed(limit: 8, defaults: defaults).map(\.name) == ["A", "C", "B"])
        #expect(RadioStore.mostPlayed(limit: 2, defaults: defaults).map(\.name) == ["A", "C"])
    }

    @Test("Teil 1: collapse keeps the best as default and attaches all variants (self included, flattened)")
    func variantsAttached() {
        let raw = [
            RadioStation(id: "radio:rb:hi", name: "Radio X 192k MP3", streamURL: "https://s/hi",
                         countryCode: "DE", bitrate: 192, codec: "MP3"),
            RadioStation(id: "radio:rb:lo", name: "Radio X 64k AAC", streamURL: "https://s/lo",
                         countryCode: "DE", bitrate: 64, codec: "AAC"),
        ]
        let out = RadioMapping.collapseVariants(raw)
        #expect(out.count == 1)
        #expect(out[0].id == "radio:rb:hi")                                    // highest bitrate = default
        #expect(out[0].variantList.map(\.id) == ["radio:rb:hi", "radio:rb:lo"]) // ranked, self included
        #expect(out[0].variantList.allSatisfy { $0.variants == nil })          // no nesting
        #expect(RadioMapping.collapseVariants([raw[0]])[0].variantList.isEmpty) // lone station → no picker
    }

    @Test("Teil 1: qualityLabel formats bitrate and codec")
    func qualityLabels() {
        func st(_ b: Int?, _ c: String?) -> RadioStation {
            RadioStation(id: "x", name: "X", streamURL: "https://s", bitrate: b, codec: c)
        }
        #expect(st(128, "mp3").qualityLabel == "128 kbps · MP3")
        #expect(st(nil, "AAC").qualityLabel == "AAC")
        #expect(st(96, nil).qualityLabel == "96 kbps")
        #expect(!st(nil, nil).qualityLabel.isEmpty)   // generic fallback (localized)
    }

    @Test("Teil 1: variant selection persists per station (stable key) and resolves the effective stream")
    func variantSelection() {
        let name = "radio-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let raw = [
            RadioStation(id: "radio:rb:hi", name: "Deutschlandfunk MP3 192k", streamURL: "https://s/hi",
                         countryCode: "DE", bitrate: 192, codec: "MP3"),
            RadioStation(id: "radio:rb:lo", name: "Deutschlandfunk AAC 64k", streamURL: "https://s/lo",
                         countryCode: "DE", bitrate: 64, codec: "AAC"),
        ]
        let station = RadioMapping.collapseVariants(raw)[0]
        // No selection → best stream.
        #expect(RadioMapping.effectiveStreamURL(
            for: station, selectedURL: RadioStore.selectedVariantURL(for: station, defaults: defaults)) == "https://s/hi")
        // Choose the low variant → persisted and resolved.
        RadioStore.setSelectedVariant("https://s/lo", for: station, defaults: defaults)
        #expect(RadioStore.selectedVariantURL(for: station, defaults: defaults) == "https://s/lo")
        #expect(RadioMapping.effectiveStreamURL(for: station, selectedURL: "https://s/lo") == "https://s/lo")
        // The key ignores codec/bitrate decorations → two variants of one station
        // (same country) share the key, so the choice survives catalog rotation.
        #expect(RadioMapping.variantKey(for: raw[0]) == RadioMapping.variantKey(for: raw[1]))
        // Selecting the default clears the override.
        RadioStore.setSelectedVariant("https://s/hi", for: station, defaults: defaults)
        #expect(RadioStore.selectedVariantURL(for: station, defaults: defaults) == nil)
        // A stale selection (no longer a variant) falls back to the best.
        #expect(RadioMapping.effectiveStreamURL(for: station, selectedURL: "https://gone") == "https://s/hi")
    }

    @Test("F4-discovery: catalog query construction per endpoint")
    func catalogQueries() {
        func params(_ q: RadioBrowserClient.Query) -> [String: String] {
            Dictionary(uniqueKeysWithValues: q.queryItems.map { ($0.name, $0.value ?? "") })
        }
        let popular = RadioBrowserClient.Query.popular(limit: 40)
        #expect(popular.path == "/json/stations/topvote")
        #expect(params(popular)["limit"] == "40")
        #expect(params(popular)["hidebroken"] == "true")

        let region = RadioBrowserClient.Query.byRegion(countryCode: "CH", limit: 40)
        #expect(region.path == "/json/stations/bycountrycodeexact/CH")
        #expect(params(region)["order"] == "votes")
        #expect(params(region)["reverse"] == "true")
        #expect(params(region)["limit"] == "40")

        let tag = RadioBrowserClient.Query.byTag(tag: "news", limit: 40)
        #expect(tag.path == "/json/stations/bytagexact/news")
        #expect(params(tag)["order"] == "votes")

        // Tag with a space is path-escaped, not left raw.
        let spaced = RadioBrowserClient.Query.byTag(tag: "hip hop", limit: 40)
        #expect(!spaced.path.contains(" "))
        #expect(spaced.path.hasPrefix("/json/stations/bytagexact/"))

        let search = RadioBrowserClient.Query.search(name: "dlf", limit: 50)
        #expect(search.path == "/json/stations/search")
        #expect(params(search)["name"] == "dlf")
        #expect(params(search)["limit"] == "50")
    }

    @Test("F4-discovery: curated genre list maps display names to Radio Browser tags")
    func curatedGenres() {
        let tags = RadioCatalog.genres.map(\.tag)
        #expect(tags.contains("news"))
        #expect(tags.contains("classical"))
        #expect(tags.contains("jazz"))
        #expect(tags.count >= 8)
        // Tags are unique, and every genre carries a glyph + a non-empty title.
        #expect(Set(tags).count == tags.count)
        #expect(RadioCatalog.genres.allSatisfy { !$0.systemImage.isEmpty && !$0.title.isEmpty })
    }

    @Test("F4-discovery: section-visibility gates (offline / region / genres)")
    func discoveryGates() {
        let one = [RadioStation(id: "radio:rb:a", name: "A", streamURL: "https://s/a")]
        // Popular: online + non-empty.
        #expect(RadioCatalog.showsPopular(isConnected: true, popular: one))
        #expect(!RadioCatalog.showsPopular(isConnected: false, popular: one))
        #expect(!RadioCatalog.showsPopular(isConnected: true, popular: []))
        // Region: online + a region code + non-empty results.
        #expect(RadioCatalog.showsRegion(isConnected: true, regionCode: "CH", regional: one))
        #expect(!RadioCatalog.showsRegion(isConnected: true, regionCode: nil, regional: one))
        #expect(!RadioCatalog.showsRegion(isConnected: true, regionCode: "CH", regional: []))
        #expect(!RadioCatalog.showsRegion(isConnected: false, regionCode: "CH", regional: one))
        // Genres: online only (tiles are static, targets are net-gated).
        #expect(RadioCatalog.showsGenres(isConnected: true))
        #expect(!RadioCatalog.showsGenres(isConnected: false))
        // Region code derives from the locale, uppercased; missing region → nil.
        #expect(RadioCatalog.deviceRegionCode(locale: Locale(identifier: "de_CH")) == "CH")
        #expect(RadioCatalog.deviceRegionCode(locale: Locale(identifier: "en")) == nil)
    }

    @Test("F3: radio never enqueues — play only replaces the active playback")
    func queueVeto() {
        #expect(!PlayQueue.canEnqueue("radio:rb:abc"))
        #expect(!PlayQueue.canEnqueue("radio:manual:xyz"))
        #expect(PlayQueue.canEnqueue("rss:show:ep"))
        #expect(PlayQueue.canEnqueue("sub:album:1"))
        #expect(PlayQueue.canEnqueue("book-id"))
    }
}
#endif
