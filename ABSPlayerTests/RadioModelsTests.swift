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
