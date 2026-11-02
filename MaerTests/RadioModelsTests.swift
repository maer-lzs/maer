// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// The pure radio core. Station mapping (mirror de-dupe), manual-station
/// validation, ICY parsing, the store round-trip and the queue veto.
struct RadioModelsTests {
    private func raw(_ uuid: String, name: String = "Station", url: String = "https://s.example/a",
                     resolved: String? = nil, country: String? = nil,
                     bitrate: Int? = nil, codec: String? = nil) -> RadioBrowserStation {
        RadioBrowserStation(stationuuid: uuid, name: name, url: url, urlResolved: resolved,
                            favicon: nil, homepage: nil, countrycode: country, tags: "jazz,news",
                            bitrate: bitrate, codec: codec, votes: nil, languagecodes: nil)
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
        // Three variants of the same station (distinct uuids, different urls).
        // Highest bitrate wins; a genuinely different station stays.
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
        // "de " across its codec variants. They must still fold to ONE.
        let folded = RadioMapping.stations(from: [
            raw("d1", name: "Deutschlandfunk | DLF | MP3 128k", url: "https://s/1", country: "DE"),
            raw("d2", name: "Deutschlandfunk | DLF | AAC 48k", url: "https://s/2", country: ""),
            raw("d3", name: "Deutschlandfunk | DLF | OPUS 24k", url: "https://s/3", country: "de "),
        ])
        #expect(folded.count == 1)

        // But two genuinely different same-named stations in different countries
        // (both codes present, different) stay apart. No mis-fusion.
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

    @Test("R26: spacing variants fold ONLY with the same homepage domain as witness")
    func spacingVariantsFoldWithDomainWitness() {
        // Iran International (NEWS) vs iraninternational (IRAN): same brand,
        // same domain. ONE row.
        let folded = RadioMapping.collapseVariants([
            RadioStation(id: "radio:rb:i1", name: "Iran International",
                         streamURL: "https://s/1", homepage: "https://iranintl.com"),
            RadioStation(id: "radio:rb:i2", name: "iraninternational",
                         streamURL: "https://s/2", homepage: "https://www.iranintl.com/live"),
        ])
        #expect(folded.count == 1)
        // Same squeezed name, DIFFERENT domains: two real stations, kept apart
        // (the domain guard. The domain is the witness, never the name alone).
        let apart = RadioMapping.collapseVariants([
            RadioStation(id: "radio:rb:a", name: "Star FM",
                         streamURL: "https://s/a", homepage: "https://starfm.de"),
            RadioStation(id: "radio:rb:b", name: "StarFM",
                         streamURL: "https://s/b", homepage: "https://starfm.ch"),
        ])
        #expect(apart.count == 2)
        // No homepage on either side: never folded by squeezing.
        let noWitness = RadioMapping.collapseVariants([
            RadioStation(id: "radio:rb:c", name: "Radio One", streamURL: "https://s/c"),
            RadioStation(id: "radio:rb:d", name: "RadioOne", streamURL: "https://s/d"),
        ])
        #expect(noWitness.count == 2)
    }

    @Test("b10aa93: the popular fill excludes core stations by NAME too (Swiss-Pop twice)")
    func coreFillExcludesByName() {
        // The core entry resolved a different host (stream fallback) than the
        // catalog copy. The identity key differs, the folded name must catch it.
        let core = [RadioStation(id: "radio:rb:core", name: "Radio Swiss Pop",
                                 streamURL: "https://stream.srg-ssr.ch/rsp")]
        let copy = RadioStation(id: "radio:rb:copy", name: "Radio Swiss Pop",
                                streamURL: "https://other.cdn/rsp",
                                homepage: "https://radioswisspop.ch")
        let row = RadioRotation.composeWithCore(core: core, votes: [copy],
                                                clicktrend: [], seed: 7, limit: 10)
        #expect(row.filter { RadioMapping.displayName($0.name) == "Radio Swiss Pop" }.count == 1)
    }

    @Test("R28: expanded family sorts games numerically, unnumbered members behind")
    func familyGamesSortNumerically() {
        func s(_ id: String, _ name: String) -> RadioStation {
            RadioStation(id: "radio:rb:\(id)", name: name,
                         streamURL: "https://s/\(id)",
                         homepage: "https://livecenter.sportschau.de")
        }
        let families = RadioGenreFamilies.collapsed([
            s("k", "Fußball-Bundesliga: Konferenz"),
            s("g8", "Fußball-Bundesliga: Spiel 8"),
            s("g2", "Fußball-Bundesliga: Spiel 2"),
            s("gx", "Fußball-Bundesliga: Sondersendung"),
            s("g5", "Fußball-Bundesliga: Spiel 5"),
        ])
        #expect(families.count == 1)
        let family = families[0]
        #expect(RadioMapping.displayName(family.front.name).contains("Konferenz"))
        #expect(family.variants.map(\.id) ==
                ["radio:rb:g2", "radio:rb:g5", "radio:rb:g8", "radio:rb:gx"])
        #expect(RadioGenreFamilies.memberNumber("Fußball-Bundesliga: Spiel 8") == 8)
        #expect(RadioGenreFamilies.memberNumber("Fußball-Bundesliga: Konferenz") == nil)
    }

    @Test("Y57→e4bd910: equal bitrate prefers AAC (Nachtrag FINAL); different country is not merged")
    func collapseTieBreakAndCountry() {
        let tie = RadioMapping.collapseVariants([
            RadioStation(id: "radio:rb:a", name: "Radio X AAC", streamURL: "https://s/a", countryCode: "DE", bitrate: 128, codec: "AAC"),
            RadioStation(id: "radio:rb:b", name: "Radio X MP3", streamURL: "https://s/b", countryCode: "DE", bitrate: 128, codec: "MP3"),
        ])
        #expect(tie.map(\.id) == ["radio:rb:a"])   // AAC wins the tie (agreed final)

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

    @Test("Teil 2: ICY artwork lookup gates on artist+title and builds a MusicBrainz query")
    func icyArtworkLookup() {
        #expect(!RadioArtworkLookup.shouldLookup(artist: nil, title: "Song"))
        #expect(!RadioArtworkLookup.shouldLookup(artist: "  ", title: "Song"))
        #expect(!RadioArtworkLookup.shouldLookup(artist: "Artist", title: ""))
        #expect(RadioArtworkLookup.shouldLookup(artist: "Daft Punk", title: "One More Time"))
        // Case/space-insensitive, stable cache key.
        #expect(RadioArtworkLookup.cacheKey(artist: " Daft Punk ", title: "One More Time")
              == RadioArtworkLookup.cacheKey(artist: "daft punk", title: "one more time"))
        // MB recording endpoint, JSON, quoted title AND artist.
        let url = RadioArtworkLookup.musicBrainzQueryURL(artist: "Daft Punk", title: "One More Time")
        #expect(url?.absoluteString.hasPrefix("https://musicbrainz.org/ws/2/recording?") == true)
        let comps = URLComponents(url: url!, resolvingAgainstBaseURL: false)!
        #expect(comps.queryItems?.contains(URLQueryItem(name: "fmt", value: "json")) == true)
        #expect(comps.queryItems?.first { $0.name == "query" }?.value
              == "recording:\"One More Time\" AND artist:\"Daft Punk\"")
    }

    @Test("Teil 2: first release MBID is picked across the returned recordings")
    func firstReleaseMBID() {
        let json = Data(#"{"recordings":[{"releases":[]},{"releases":[{"id":"mbid-1"},{"id":"mbid-2"}]}]}"#.utf8)
        let decoded = try! JSONDecoder().decode(MBRecordingResponse.self, from: json)
        #expect(RadioArtworkLookup.firstReleaseMBID(decoded) == "mbid-1")
        let empty = try! JSONDecoder().decode(MBRecordingResponse.self, from: Data(#"{"recordings":[]}"#.utf8))
        #expect(RadioArtworkLookup.firstReleaseMBID(empty) == nil)
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

        // The genre query rides the SEARCH endpoint. Measured
        // byte-identical to the old `bytagexact` path, so one endpoint serves
        // both the worldwide and the country-narrowed case.
        let tag = RadioBrowserClient.Query.byTag(tag: "news", countryCode: nil, limit: 40)
        #expect(tag.path == "/json/stations/search")
        #expect(params(tag)["tag"] == "news")
        // `tagExact` is a BOOLEAN. Passing the tag as its value silently drops
        // the tag and answers with the whole country (measured).
        #expect(params(tag)["tagExact"] == "true")
        #expect(params(tag)["order"] == "votes")
        #expect(params(tag)["countrycode"] == nil)

        // Tag with a space rides the query, not the path. No escaping needed.
        let spaced = RadioBrowserClient.Query.byTag(tag: "hip hop", countryCode: nil, limit: 40)
        #expect(!spaced.path.contains(" "))
        #expect(params(spaced)["tag"] == "hip hop")

        let narrowed = RadioBrowserClient.Query.byTag(tag: "news", countryCode: "ch", limit: 40)
        #expect(params(narrowed)["countrycode"] == "CH")

        // The language pot filters CLIENT-side and case-INsensitive.
        // The catalog field is mixed-case (DLF carries "DE", WDR 5 "de"),
        // and the server's `languagecodes=` filter is case-sensitive (an
        // uppercase parameter is even ignored, measured live). `speaks` is
        // that filter: the station side lowercases, the caller lowercases.
        let dlf = RadioStation(id: "radio:rb:dlf", name: "Deutschlandfunk",
                               streamURL: "http://x", languageCodes: ["DE"])
        #expect(RadioGenreCuration.speaks(dlf, "de"))
        let wdr = RadioStation(id: "radio:rb:wdr5", name: "WDR 5",
                               streamURL: "http://x", languageCodes: ["de"])
        #expect(RadioGenreCuration.speaks(wdr, "de"))
        #expect(!RadioGenreCuration.speaks(dlf, "fr"))

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

@Test("mirror loop propagates cancellation instead of walking all mirrors")
func radioBrowserCancellationPropagates() async {
    let task = Task {
        // Deterministic: cancel ourselves BEFORE the call. The loop's
        // checkCancellation must throw on entry, no network is touched.
        withUnsafeCurrentTask { $0?.cancel() }
        return try await RadioBrowserClient.stations(.popular(limit: 1))
    }
    do {
        _ = try await task.value
        Issue.record("expected CancellationError")
    } catch is CancellationError {
        // expected: immediate propagation
    } catch {
        Issue.record("expected CancellationError, got \(error)")
    }
}



/// A failed discovery run never replaces the rows that stand, nor the
/// cache they came from, and does not count as loaded.
struct RadioDiscoveryStepTests {
    @Test("ein gescheiterter Entdecken-Lauf ersetzt weder die stehende Reihe noch den Zwischenstand und zaehlt nicht als geladen; ohne Reihe sagt er es", .needsTheSources)
    func aFailedRunKeepsWhatStands() throws {
        #expect(RadioStore.discoveryStep(failed: false, standing: true) == .replace)
        #expect(RadioStore.discoveryStep(failed: false, standing: false) == .replace)
        #expect(RadioStore.discoveryStep(failed: true, standing: true) == .keep, "a failed run replaced the standing rows")
        #expect(RadioStore.discoveryStep(failed: true, standing: false) == .failed)
        // The view asks the rule before it writes the cache or the rows,
        // and the step that keeps returns before both.
        let code = SyncContractFenceTests.stripped(try String(contentsOf: SourceTree.root.appendingPathComponent(
            "Sources/Views/Radio/RadioView.swift"), encoding: .utf8))
        let step = try #require(code.range(of: "RadioStore.discoveryStep(failed: topFailed, standing: !popular.isEmpty)"),
                                "the view does not ask the rule")
        let save = try #require(code.range(of: "RadioStore.saveDiscovery(popular: topResult"), "the view writes no cache")
        #expect(step.lowerBound < save.lowerBound, "the cache is written before the rule is asked")
        let keep = try #require(code.range(of: "case .keep:", range: step.upperBound..<save.lowerBound), "no step keeps")
        let keepBody = String(code[keep.upperBound..<save.lowerBound]).components(separatedBy: "case .replace:").first ?? ""
        #expect(keepBody.contains("return"), "the step that keeps goes on to write the cache")
    }
}

/// Region rework: the new state endpoints as pure query data.
struct RadioStateQueryTests {
    @Test("states/byState query shapes")
    func stateQueries() {
        let states = RadioBrowserClient.Query.states(countryName: "Switzerland")
        #expect(states.path == "/json/states/Switzerland/")
        let byState = RadioBrowserClient.Query.byState(state: "Zürich", limit: 40)
        #expect(byState.path.hasPrefix("/json/stations/bystateexact/"))
        #expect(byState.queryItems.contains(.init(name: "order", value: "votes")))
        #expect(byState.queryItems.contains(.init(name: "limit", value: "40")))
    }

    @Test("86cf180: icy-name rough match — folded containment, slogans pass, absence passes")
    func icyRoughMatch() {
        #expect(RadioDiagnostics.roughlyMatches(
            expectedName: "ROCK ANTENNE", icyName: "ROCK ANTENNE - der beste Rock nonstop"))
        #expect(RadioDiagnostics.roughlyMatches(expectedName: "Radio Bern", icyName: "radiobern"))
        #expect(RadioDiagnostics.roughlyMatches(expectedName: "SWR3", icyName: nil))
        #expect(RadioDiagnostics.roughlyMatches(expectedName: "SWR3", icyName: "  "))
        // A truly foreign stream announces itself. This is the loud line.
        #expect(!RadioDiagnostics.roughlyMatches(
            expectedName: "ROCK ANTENNE", icyName: "Radio Studio Piu Italia"))
    }

    @Test("6b3a35d: display name — pipe junk trimmed, short heads keep the full name")
    func displayNames() {
        #expect(RadioMapping.displayName("Deutschlandfunk Kultur | DLF | 128k")
                == "Deutschlandfunk Kultur")
        #expect(RadioMapping.displayName("SWR3 • Pop") == "SWR3")
        #expect(RadioMapping.displayName("Radio Bern") == "Radio Bern")
        // Nachtrag (4): codec/bitrate TAIL junk without separators.
        #expect(RadioMapping.displayName("Deutschlandfunk AAC 192k") == "Deutschlandfunk")
        #expect(RadioMapping.displayName("Antenne Bayern mp3 128kbps") == "Antenne Bayern")
        #expect(RadioMapping.displayName("SWR3 Stream 2") == "SWR3")
        // Genre words that LOOK like codecs stay (no mid-name stripping).
        #expect(RadioMapping.displayName("Opus Klassik Radio") == "Opus Klassik Radio")
        // A too-short head keeps the raw name (never truncate to junk).
        #expect(RadioMapping.displayName("A | Station") == "A | Station")
    }

    @Test("AAC+ am Namensende faellt wie AAC: in der Anzeige und im Gruppenschluessel, ein Plus mitten im Namen bleibt")
    func aacPlusAtTheEndIsStripped() {
        #expect(RadioMapping.displayName("Radio Wien AAC+") == "Radio Wien")
        #expect(RadioMapping.displayName("Radio Wien AAC+ 64k") == "Radio Wien")
        #expect(RadioMapping.displayName("FM4 HE-AAC+") == "FM4")
        #expect(RadioMapping.normalizedStationName("Radio Wien AAC+") == "radio wien")
        #expect(RadioMapping.normalizedStationName("Radio Wien | AAC+ 64k") == "radio wien")
        // An AAC inside a word, and a plus that is part of the name, stay.
        #expect(RadioMapping.displayName("Canal+ Radio") == "Canal+ Radio")
        #expect(RadioMapping.displayName("Radio Aachen") == "Radio Aachen")
    }

    @Test("e4bd910: logo chain pure pieces — conservative entity match, P154, touch icon")
    func logoLookup() throws {
        // Conservative Wikidata match: label must fold-contain the name.
        let search = Data("""
        {"search":[{"id":"Q999","label":"Rock am Ring"},{"id":"Q42","label":"ROCK ANTENNE"}]}
        """.utf8)
        #expect(RadioLogoLookup.matchedEntity(fromSearchData: search, stationName: "Rock Antenne")?.id == "Q42")
        #expect(RadioLogoLookup.matchedEntity(fromSearchData: search, stationName: "Deutschlandfunk") == nil)
        // P154 via the SHARED claim parser.
        let entity = Data("""
        {"entities":{"Q42":{"claims":{"P154":[{"mainsnak":{"datavalue":{"value":"Rock Antenne Logo.svg"}}}]}}}}
        """.utf8)
        #expect(RadioLogoLookup.p154FileName(fromEntityData: entity, entity: "Q42") == "Rock Antenne Logo.svg")
        // Touch-icon extraction incl. relative href; convention fallback.
        let base = try #require(URL(string: "https://www.rockantenne.de/player"))
        let html = "<head><link rel=\"stylesheet\" href=\"a.css\"><link rel=\"apple-touch-icon\" href=\"/icons/touch.png\"></head>"
        #expect(RadioLogoLookup.extractTouchIcon(html: html, baseURL: base)?.absoluteString
                == "https://www.rockantenne.de/icons/touch.png")
        // With MANY declared sizes the LARGEST wins. Sportschau
        // lists 57 first, and taking the first put a mushy icon on every
        // Bundesliga tile.
        let sized = """
        <link rel="apple-touch-icon" sizes="57x57" href="/i/a-57.png">
        <link rel="apple-touch-icon" sizes="152x152" href="/i/a-152.png">
        <link rel="apple-touch-icon" sizes="120x120" href="/i/a-120.png">
        """
        #expect(RadioLogoLookup.extractTouchIcon(html: sized, baseURL: base)?.absoluteString
                == "https://www.rockantenne.de/i/a-152.png")
        // A sizeless tag is the modern default (large). It must beat a
        // legacy small declaration, not lose to it.
        let mixed = """
        <link rel="apple-touch-icon" sizes="57x57" href="/i/a-57.png">
        <link rel="apple-touch-icon" href="/i/a-default.png">
        """
        #expect(RadioLogoLookup.extractTouchIcon(html: mixed, baseURL: base)?.absoluteString
                == "https://www.rockantenne.de/i/a-default.png")
        #expect(RadioLogoLookup.extractTouchIcon(html: "<head></head>", baseURL: base) == nil)
        #expect(RadioLogoLookup.conventionTouchIconURL(homepage: base)?.absoluteString
                == "https://www.rockantenne.de/apple-touch-icon.png")
        // Diagnose-getrieben: brand-stem variant finds "90s90s" for
        // "90s90s Dance HQ"; the fold containment accepts the short label.
        #expect(RadioLogoLookup.searchTerms(for: "90s90s Dance HQ") == ["90s90s Dance HQ", "90s90s"])
        #expect(RadioLogoLookup.searchTerms(for: "MANGORADIO") == ["MANGORADIO"])
        // Family suffix: the brand prefix before " - " joins the terms.
        #expect(RadioLogoLookup.searchTerms(for: "Sunshine Live - Techno")
                == ["Sunshine Live - Techno", "Sunshine Live", "Sunshine"])
        #expect(RadioLogoLookup.searchTerms(for: "Hit Radio FFH - 80er")
                == ["Hit Radio FFH - 80er", "Hit Radio FFH"])
        // A proper-subset label needs a RADIO word in label or
        // description. The plain brand stem now travels with its measured
        // description ("radio station in Germany").
        let search90 = Data("""
        {"search":[{"id":"Q105475115","label":"90s90s","description":"radio station in Germany"}]}
        """.utf8)
        #expect(RadioLogoLookup.matchedEntity(fromSearchData: search90,
                                              stationName: "90s90s Dance HQ")?.id == "Q105475115")
    }

    /// The runtime P154 stage PERSISTS, so it carries guards. The
    /// audit caught it booking the LIFE magazine for Life Radio and Reset
    /// Media for the Reshet networks. All seven decided cases, verbatim from
    /// the live search API.
    @Test("Teilmengen-Label brauchen ein Radio-Wort; die Datei muss das Label tragen")
    func foreignMarkGuards() {
        func hit(_ id: String, _ label: String, _ desc: String) -> Data {
            Data("""
            {"search":[{"id":"\(id)","label":"\(label)","description":"\(desc)"}]}
            """.utf8)
        }
        // Foreign: a magazine and a TV house sharing the head word.
        #expect(RadioLogoLookup.matchedEntity(
            fromSearchData: hit("Q463198", "Life", "American magazine published 1883-2000"),
            stationName: "Life Radio (OÖ)") == nil)
        #expect(RadioLogoLookup.matchedEntity(
            fromSearchData: hit("Q12411482", "Reshet",
                                "Israeli television broadcasting and production company"),
            stationName: "Reshet Aleph") == nil)
        // Legitimate: radio word in the LABEL (Polskie, Sveriges) or in the
        // DESCRIPTION (90s90s, covered above).
        #expect(RadioLogoLookup.matchedEntity(
            fromSearchData: hit("Q1067189", "Polskie Radio",
                                "Polish national public broadcasting organization"),
            stationName: "Polskie Radio Białystok")?.id == "Q1067189")
        #expect(RadioLogoLookup.matchedEntity(
            fromSearchData: hit("Q1543058", "Sveriges Radio",
                                "national publicly funded radio broadcaster"),
            stationName: "Sveriges Radio P4")?.id == "Q1543058")
        // The file witness: the P154 file must carry the matched label.
        #expect(!RadioLogoLookup.fileCarriesLabel("Reset Media.svg", label: "Reshet"))
        #expect(RadioLogoLookup.fileCarriesLabel("Polskie Radio logotyp 2017.svg",
                                                 label: "Polskie Radio"))
        #expect(RadioLogoLookup.fileCarriesLabel("Logo Radio harmony.fm.svg",
                                                 label: "Radio Harmony"))
    }

    @Test("e4bd910: display dedupe — variants fold by name+domain, foreigners and siblings never")
    func displayDedupe() {
        func st(_ id: String, _ name: String, _ home: String?, bitrate: Int?, codec: String?) -> RadioStation {
            RadioStation(id: id, name: name, streamURL: "https://cdn\(id).example/stream",
                         faviconURL: nil, homepage: home, countryCode: "DE",
                         tags: [], bitrate: bitrate, codec: codec)
        }
        let stations = [
            st("1", "ROCK ANTENNE", "https://www.rockantenne.de", bitrate: 128, codec: "MP3"),
            st("2", "ROCK ANTENNE AAC 192k", "https://rockantenne.de", bitrate: 192, codec: "AAC"),
            st("3", "ROCK ANTENNE", "https://radiostudio.it", bitrate: 320, codec: "MP3"),
            st("4", "1LIVE", "https://www1.wdr.de", bitrate: 128, codec: "MP3"),
            st("5", "1LIVE Dance Hits", "https://www1.wdr.de", bitrate: 128, codec: "MP3"),
        ]
        let deduped = RadioMapping.dedupeForDisplay(stations)
        // Real variants fold (name-after-trim + domain); AAC wins the bundle,
        // the bundle carries both streams, the shown one first.
        let rock = deduped.first { PodcastIdentity.feedHost($0.homepage ?? "") == "rockantenne.de" }
        let rockStreams = rock?.variantList.map(\.id) ?? []
        #expect(deduped.count == 4)
        #expect(rock?.id == "2")
        #expect(rockStreams == ["2", "1"], "streams: \(rockStreams)")
        // The same-named FOREIGN station (other domain) stays separate…
        #expect(deduped.contains { $0.id == "3" })
        // …and program siblings never fold (name differs).
        #expect(deduped.contains { $0.id == "4" } && deduped.contains { $0.id == "5" })
    }

    /// The variant choice shows `variantList`, and the station itself is one
    /// of its streams (the house rule: self included). Three entries of one
    /// station, the last best: each stream stands once, the shown one first,
    /// the others best first (before, `a, b, a`: the earlier loser twice and
    /// the winner missing from its own list).
    @Test("die Auswahl eines gefalteten Senders zeigt jeden Strom einmal, den gezeigten zuerst")
    func aLaterWinnerCarriesEachVariantOnce() {
        let deduped = RadioMapping.dedupeForDisplay([Self.rock("a", 64), Self.rock("b", 96), Self.rock("c", 192)])
        let winner = deduped.first
        let streams = winner?.variantList.map(\.id) ?? []
        #expect(deduped.count == 1 && winner?.id == "c", "the precondition: one bundle, the best wins")
        #expect(streams == ["c", "b", "a"], "streams: \(streams)")
    }

    /// An entry that already brings variants keeps them in the bundle,
    /// whether it wins or loses, and a stream it brings twice (itself among
    /// its own variants) stands once.
    @Test("mitgebrachte Varianten bleiben in der Faltung erhalten, jeder Strom einmal")
    func broughtVariantsStayInTheBundle() {
        var winning = Self.rock("c", 192)
        winning.variants = [Self.rock("c", 192), Self.rock("x", 32)]
        var losing = Self.rock("b", 96)
        losing.variants = [Self.rock("b", 96), Self.rock("y", 48)]
        let deduped = RadioMapping.dedupeForDisplay([losing, winning])
        let streams = deduped.first?.variantList.map(\.id) ?? []
        #expect(deduped.count == 1 && deduped.first?.id == "c", "the precondition: one bundle, the best wins")
        #expect(streams == ["c", "b", "y", "x"], "streams: \(streams)")
    }

    /// The shown entry is the best of the ENTRIES, not of every stream: one
    /// may bring a better stream than itself. The shown one still stands
    /// first, the better stream after it, none twice.
    @Test("ist der gezeigte Strom nicht der beste, steht er trotzdem zuerst, der beste danach, keiner doppelt")
    func theShownStreamLeadsEvenWhenABetterOneRidesAlong() {
        var shown = Self.rock("c", 192)
        shown.variants = [Self.rock("c", 192), Self.rock("z", 320)]
        let deduped = RadioMapping.dedupeForDisplay([Self.rock("b", 96), shown])
        let streams = deduped.first?.variantList.map(\.id) ?? []
        #expect(deduped.count == 1 && deduped.first?.id == "c", "the precondition: the best entry is shown")
        #expect(streams == ["c", "z", "b"], "streams: \(streams)")
    }

    /// A stream is its address: Radio Browser lists one address under
    /// several ids (measured: Rock Antenne three times with one address,
    /// name, homepage and bitrate). Each address stands once, the shown
    /// entry for its own address, the best id for another.
    @Test("in der Auswahl steht jede Stromadresse einmal, auch wenn Radio Browser sie unter mehreren Kennungen fuehrt")
    func eachStreamAddressStandsOnce() {
        let twin = "http://mp3channels.webradio.rockantenne.de/rockantenne"
        let other = "https://cdn.example/rock-aac"
        let stations = [Self.rock("t1", 128, at: twin), Self.rock("t2", 128, at: twin), Self.rock("t3", 128, at: twin),
                        Self.rock("o1", 64, at: other), Self.rock("o2", 96, at: other)]
        let deduped = RadioMapping.dedupeForDisplay(stations)
        let streams = deduped.first?.variantList.map(\.id) ?? []
        let addresses = deduped.first?.variantList.map(\.streamURL) ?? []
        #expect(deduped.count == 1 && deduped.first?.id == "t1", "the precondition: one bundle, the first of the equal best is shown")
        #expect(streams == ["t1", "o2"], "streams: \(streams)")
        #expect(addresses == [twin, other], "addresses: \(addresses)")
    }

    /// Folding, choosing and drawing the variants take one key, the stream
    /// address: two answers of the catalog can give one id two addresses,
    /// and a list keyed by id would then hold the same id twice. The fence
    /// reads every file under Sources, so a new list is seen where it lands.
    @Test("Entdoppeln, Waehlen und Zeichnen der Varianten nehmen denselben Schluessel, die Stromadresse", .needsTheSources)
    func variantsAreKeyedByAddressEverywhere() throws {
        let models = SyncContractFenceTests.stripped(try String(
            contentsOf: SourceTree.root.appendingPathComponent("Sources/Models/RadioModels.swift"), encoding: .utf8))
        #expect(models.contains("station.variantList.contains(where: { $0.streamURL == selectedURL })"),
                "the choice is not read by address")
        let sources = SourceTree.root.appendingPathComponent("Sources")
        let files = SourceTree.files(under: sources)
            .filter { $0.pathExtension == "swift" }
        #expect(files.count > 100, "the fence read the sources")
        var drawings: [(file: String, line: String)] = []
        for file in files {
            let code = SyncContractFenceTests.stripped(try String(contentsOf: file, encoding: .utf8))
            drawings += Self.variantLists(in: code).map { (SourceTree.relativePath(of: file), $0) }
        }
        #expect(drawings.contains { $0.file == "Sources/Views/PlayerView.swift" }
                && drawings.contains { $0.file == "Sources/Views/Radio/RadioStationDetailView.swift" },
                "the fence found the lists it guards: \(drawings.map(\.file))")
        let byOtherKey = drawings.filter { !$0.line.contains("streamURL") }
        let counts = Dictionary(byOtherKey.map { ($0.file, 1) }, uniquingKeysWith: +)
        let drift = StockDrift.findings(counts: counts, stock: Self.listsByOtherKey.mapValues(\.count))
        #expect(drift.isEmpty, "a variant list is drawn by another key, or a held file has fewer: \(drift) \(byOtherKey)")
    }

    /// The station page lists the streams of every station, a single one
    /// too: a station is at least one stream.
    @Test("Jeder Sender nennt mindestens einen Stream, mit Format, Bitrate und Wirt")
    func everyStationListsAtLeastOneStream() {
        let single = RadioStation(id: "radio:rb:one", name: "Single", streamURL: "http://live.example.at/one-q2a",
                                  bitrate: 192, codec: "MP3")
        #expect(single.variantList.isEmpty, "the precondition: no alternatives")
        #expect(single.streamVariants.map(\.streamURL) == [single.streamURL])
        #expect(single.streamVariants.first?.qualityLabel == "192 kbps · MP3")
        #expect(single.streamHost == "live.example.at")
        let folded = RadioMapping.collapseVariants([
            RadioStation(id: "radio:rb:lo", name: "Two", streamURL: "https://b.example/lo", bitrate: 64),
            RadioStation(id: "radio:rb:hi", name: "Two", streamURL: "https://a.example/hi", bitrate: 192),
        ])
        #expect(folded.count == 1, "the precondition: one station with two streams")
        #expect(folded.first?.streamVariants.map(\.streamURL) == ["https://a.example/hi", "https://b.example/lo"])
        #expect(folded.first?.streamVariants.allSatisfy { $0.variants == nil } == true, "streams never nest")
        let manual = RadioStation(id: "radio:manual:own", name: "Own", streamURL: "file:///tmp/own.wav")
        #expect(manual.streamVariants.count == 1 && manual.streamHost == nil)
    }

    /// The streams stand on the station page under no condition; a count
    /// gate would leave the column empty for a station with one stream.
    @Test("Die Senderseite zeichnet ihre Streams immer, nicht erst ab zweien", .needsTheSources)
    func theStationPageAlwaysDrawsItsStreams() throws {
        let page = SyncContractFenceTests.stripped(try String(
            contentsOf: SourceTree.root.appendingPathComponent("Sources/Views/Radio/RadioStationDetailView.swift"),
            encoding: .utf8))
        #expect(page.contains("station.streamVariants"), "the page lists the streams, its own included")
        #expect(!page.contains("station.variantList"), "the page reads the alternatives only, which are empty for one stream")
        let lines = page.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        let at = lines.firstIndex(of: "streamsSection")
        #expect(at.map { lines[$0 - 1] } == "VStack(spacing: 20) {",
                "the streams open the column, under no condition")
    }

    /// The statements that draw a list of variants: a `ForEach` whose first
    /// argument names variants, or names a value this file bound to them.
    /// Read as statements, across lines, from `ForEach(` to the parenthesis
    /// that closes its arguments; a word in the closure does not count.
    static func variantLists(in code: String) -> [String] {
        let bound = variantNames(in: code)
        var found: [String] = []
        var search = code.startIndex
        while let hit = code.range(of: "ForEach(", range: search..<code.endIndex) {
            search = hit.upperBound
            var depth = 1
            var index = hit.upperBound
            var firstEnd: String.Index?
            while index < code.endIndex, depth > 0 {
                switch code[index] {
                case "(", "[": depth += 1
                case ")", "]": depth -= 1
                case "," where depth == 1 && firstEnd == nil: firstEnd = index
                default: break
                }
                if depth > 0 { index = code.index(after: index) }
            }
            guard depth == 0 else { break }
            let first = code[hit.upperBound..<(firstEnd ?? index)]
            let names = Set(first.split { !($0.isLetter || $0.isNumber || $0 == "_") }.map(String.init))
            guard first.lowercased().contains("variant") || !names.isDisjoint(with: bound) else { continue }
            found.append(("ForEach(" + code[hit.upperBound...index]).split(whereSeparator: \.isWhitespace).joined(separator: " "))
        }
        return found
    }

    /// Names this file binds to variants (`let streams = station.variantList`).
    /// Every binding on a line counts, each read up to the next one.
    static func variantNames(in code: String) -> Set<String> {
        var names: Set<String> = []
        for line in code.split(separator: "\n") {
            let bindings = line.matches(of: #/(?:let|var)\s+([A-Za-z_][A-Za-z0-9_]*)/#)
            for (offset, binding) in bindings.enumerated() {
                let end = offset + 1 < bindings.count ? bindings[offset + 1].range.lowerBound : line.endIndex
                let value = line[binding.range.upperBound..<end]
                guard value.contains("=") || value.contains("{"), value.lowercased().contains("variant") else { continue }
                names.insert(String(binding.output.1))
            }
        }
        return names
    }

    /// Lists of variants drawn by another key than the stream address: how
    /// many in each file, and why.
    static let listsByOtherKey: [String: (count: Int, reason: String)] = [
        // The members of a genre family are separate stations, not stream
        // variants of one. The page list is deduplicated by display identity
        // (`RadioGenreCuration.deduped`), and the world core replaces its
        // matches by the same key (`withWorldCore`), one station per name.
        "Sources/Views/Radio/RadioGenreView.swift": (1, "genre family members are separate stations"),
    ]

    @Test("Der Varianten-Zaun sieht eine Liste nach Kennung und nach Adresse, auch mehrzeilig und unter anderem Namen")
    func theVariantFenceSeesBothKeys() {
        let planted = """
        ForEach(station.variantList) { variant in
        ForEach(station.variantList, id: \\.streamURL) { variant in
        ForEach(rows) { variant in
        let streams = station.variantList
        ForEach(
            streams
        ) { stream in
        """
        let found = Self.variantLists(in: planted)
        #expect(found.count == 3, "the reader sees the three variant lists and not the rows: \(found)")
        #expect(found.filter { !$0.contains("streamURL") }.count == 2, "the two by id are told apart: \(found)")
        #expect(found.contains("ForEach( streams )"), "a list under another name, across lines, is seen: \(found)")
        // Two bindings on one line: the second is read too.
        let packed = "var page: some View { let feeds = station.variantList; return ForEach(feeds) { s in Text(s.name) } }"
        #expect(Self.variantLists(in: packed) == ["ForEach(feeds)"], "the second binding of a line is read")
    }

    /// One entry of the station of these findings.
    private static func rock(_ id: String, _ bitrate: Int, at address: String? = nil) -> RadioStation {
        RadioStation(id: id, name: "ROCK ANTENNE", streamURL: address ?? "https://cdn\(id).example/stream",
                     faviconURL: nil, homepage: "https://www.rockantenne.de", countryCode: "DE",
                     tags: [], bitrate: bitrate, codec: "MP3")
    }

    @Test("e4bd910: rotation — socket constant, same seed identical, new day differs")
    func rotation() {
        func st(_ id: String) -> RadioStation {
            RadioStation(id: id, name: "S\(id)", streamURL: "https://h\(id).example/s",
                         faviconURL: nil, homepage: "https://h\(id).example", countryCode: "DE",
                         tags: [], bitrate: nil, codec: nil)
        }
        let votes = (1...30).map { st("v\($0)") }
        let trend = (1...30).map { st("t\($0)") }
        let a = RadioRotation.compose(votes: votes, clicktrend: trend,
                                      seed: RadioRotation.seed(day: 20_260_803, countryCode: "DE"), limit: 12)
        let b = RadioRotation.compose(votes: votes, clicktrend: trend,
                                      seed: RadioRotation.seed(day: 20_260_803, countryCode: "DE"), limit: 12)
        let c = RadioRotation.compose(votes: votes, clicktrend: trend,
                                      seed: RadioRotation.seed(day: 20_260_804, countryCode: "DE"), limit: 12)
        // Socket: seats 1–3 are ALWAYS the clicktrend top.
        #expect(a.prefix(3).map(\.id) == ["t1", "t2", "t3"])
        #expect(c.prefix(3).map(\.id) == ["t1", "t2", "t3"])
        // Same seed ⇒ identical row; new day ⇒ a different mix.
        #expect(a.map(\.id) == b.map(\.id))
        #expect(a.map(\.id) != c.map(\.id))
        #expect(a.count == 12)
        // Country changes the seed too.
        #expect(RadioRotation.seed(day: 1, countryCode: "DE") != RadioRotation.seed(day: 1, countryCode: "AT"))
    }

    @Test("71b277f: regional socket sits on VOTES; trend needs the votes floor")
    func regionalSocket() {
        func st(_ id: String, votes: Int) -> RadioStation {
            RadioStation(id: id, name: "S\(id)", streamURL: "https://h\(id).example/s",
                         faviconURL: nil, homepage: "https://h\(id).example", countryCode: "DE",
                         tags: [], bitrate: nil, codec: nil, votes: votes)
        }
        let votes = [st("wdr2", votes: 900), st("1live", votes: 800), st("wdr4", votes: 700),
                     st("v4", votes: 100), st("v5", votes: 90)]
        // The noise class: click-spike webradios with next to no vote mass.
        let trend = [st("eifellounge", votes: 3), st("teuto", votes: 2), st("technolovers", votes: 1)]
        let row = RadioRotation.compose(votes: votes, clicktrend: trend,
                                        seed: RadioRotation.seed(day: 20_260_803, countryCode: "NRW"),
                                        limit: 5, socket: .votes, minTrendVotes: 50)
        // Socket = the stable vote mass, never the spikes.
        #expect(row.prefix(3).map(\.id) == ["wdr2", "1live", "wdr4"])
        // The floored trend spikes never enter the pool at all.
        #expect(!row.contains { ["eifellounge", "teuto", "technolovers"].contains($0.id) })
        // National keeps the clicktrend socket (device-proven correct).
        let national = RadioRotation.compose(votes: votes, clicktrend: trend,
                                             seed: 1, limit: 5)
        #expect(national.prefix(3).map(\.id) == ["eifellounge", "teuto", "technolovers"])
    }

    @Test("26b2c13: discovery cache round-trips the composed rows for frame 1")
    func discoveryCache() {
        let defaults = UserDefaults(suiteName: "discovery-cache-test")!
        defaults.removePersistentDomain(forName: "discovery-cache-test")
        // Nothing stored yet ⇒ nil, and the cold start simply stays empty.
        #expect(RadioStore.cachedDiscovery(defaults: defaults) == nil)

        let popular = [RadioStation(id: "radio:rb:p1", name: "WDR 2", streamURL: "https://s/1",
                                    countryCode: "DE")]
        let regional = [RadioStation(id: "radio:rb:r1", name: "Antenne", streamURL: "https://s/2",
                                     countryCode: "DE")]
        RadioStore.saveDiscovery(popular: popular, regional: regional,
                                 day: 20_260_803, defaults: defaults)
        let cached = RadioStore.cachedDiscovery(defaults: defaults)
        #expect(cached?.popular.map(\.id) == ["radio:rb:p1"])
        #expect(cached?.regional.map(\.id) == ["radio:rb:r1"])
        // The day rides along so a stale day is recognizable (it is shown
        // anyway (stale beats blank) and replaced by the fresh composition).
        #expect(cached?.day == 20_260_803)

        // A later composition overwrites in place (no growth, no merge).
        RadioStore.saveDiscovery(popular: [], regional: regional,
                                 day: 20_260_804, defaults: defaults)
        #expect(RadioStore.cachedDiscovery(defaults: defaults)?.popular.isEmpty == true)
        defaults.removePersistentDomain(forName: "discovery-cache-test")
    }

    @Test("95c5c16: the frame-1 cache round-trip keeps favicon and homepage")
    func discoveryCacheKeepsArtworkFields() {
        let defaults = UserDefaults(suiteName: "discovery-roundtrip-test")!
        defaults.removePersistentDomain(forName: "discovery-roundtrip-test")
        let station = RadioStation(
            id: "radio:rb:mango", name: "MANGORADIO",
            streamURL: "https://stream/mango",
            faviconURL: "https://mangoradio.de/favicon-192.webp",
            homepage: "https://mangoradio.de",
            countryCode: "DE", tags: ["pop"], bitrate: 128, codec: "MP3", votes: 500)
        RadioStore.saveDiscovery(popular: [station], regional: [], day: 20_260_804,
                                 defaults: defaults)
        let restored = RadioStore.cachedDiscovery(defaults: defaults)?.popular.first
        // Without these two the logo chain has NO first stage. The second
        // suspect behind "all tiles are placeholders".
        #expect(restored?.faviconURL == station.faviconURL)
        #expect(restored?.homepage == station.homepage)
        #expect(restored?.id == station.id)
        #expect(restored?.bitrate == 128)
        #expect(restored?.votes == 500)
        defaults.removePersistentDomain(forName: "discovery-roundtrip-test")
    }

    @Test("a4e747e: a country-filtered list drops foreign entries, keeps empty codes")
    func countryContext() {
        let de = RadioStation(id: "radio:rb:de", name: "Rock Antenne",
                              streamURL: "https://de/stream", countryCode: "DE",
                              bitrate: 128, codec: "MP3")
        let it = RadioStation(id: "radio:rb:it", name: "Rock Antenne",
                              streamURL: "https://it/stream", countryCode: "IT",
                              bitrate: 320, codec: "MP3")
        let unknown = RadioStation(id: "radio:rb:x", name: "Rock Antenne",
                                   streamURL: "https://x/stream", countryCode: nil,
                                   bitrate: 64, codec: "MP3")
        let kept = RadioMapping.keepingCountry("DE", in: [de, it, unknown])
        // The Italian entry goes even though its bitrate is the best. In a
        // DE list it must never become the default (device report).
        #expect(kept.map(\.id) == ["radio:rb:de", "radio:rb:x"])
        // Lower case and stray whitespace behave the same.
        #expect(RadioMapping.keepingCountry(" de ", in: [de, it]).map(\.id) == ["radio:rb:de"])
        // WITHOUT a country context nothing is dropped (world list).
        #expect(RadioMapping.keepingCountry("", in: [de, it, unknown]).count == 3)

        // And the collapse afterwards can no longer pick the Italian variant,
        // because it is not in the pool any more.
        let collapsed = RadioMapping.collapseVariants(kept)
        #expect(collapsed.allSatisfy { $0.id != "radio:rb:it" })
    }
}
#endif

// MARK: - First-hand listener cores

/// The resolve ladder is fixture-tested against REAL catalog names from the
/// reference run (2026-08-15, de1.api.radio-browser.info). Every fixture
/// name below is a real RB entry that shaped a ladder rule.
struct RadioListenerCoreTests {
    private func rb(_ id: String, _ name: String, votes: Int = 0, cc: String = "DE") -> RadioStation {
        RadioStation(id: "radio:rb:\(id)", name: name, streamURL: "https://s/\(id)",
                     countryCode: cc, votes: votes)
    }

    @Test func coreTablesAreWellFormed() {
        for code in ["DE", "AT", "CH"] {
            let core = RadioListenerCores.national(countryCode: code)
            #expect(core != nil && !(core ?? []).isEmpty)
            #expect(Set(core ?? []).count == (core ?? []).count)   // no dupes
        }
        // Priority chain: countries without a survey fall to
        // the Wikidata core; countries without either stay votes-pure.
        #expect(RadioListenerCores.national(countryCode: "FR")?.isEmpty == false)
        #expect(RadioListenerCores.national(countryCode: "FR")
            == RadioWikidataCores.national(countryCode: "FR"))
        #expect(RadioListenerCores.national(countryCode: "DE")
            == RadioListenerCores.germanyNational)   // survey beats Wikidata
        #expect(RadioListenerCores.national(countryCode: "XK") == nil)
        #expect(RadioListenerCores.national(countryCode: nil) == nil)
    }

    @Test func regionalTablesMatchTheCanon() {
        // Every regional core key must resolve through the canon. A typo in
        // a table key would silently disable that Land's core.
        for (code, table) in [("DE", RadioListenerCores.germanyRegional),
                              ("AT", RadioListenerCores.austriaRegional)] {
            let canonDisplays = Set((RadioRegionCanon.tables[code] ?? []).map(\.display))
            for key in table.keys {
                #expect(canonDisplays.contains(key), "\(code)/\(key) not in canon")
                #expect(RadioListenerCores.regional(countryCode: code, regionName: key) != nil)
            }
        }
        #expect(RadioListenerCores.germanyRegional.count == 16)
        #expect(RadioListenerCores.austriaRegional.count == 9)
        // Aliases resolve too (the picker may hand the alias spelling).
        #expect(RadioListenerCores.regional(countryCode: "DE", regionName: "NRW") != nil)
        // CH regional stays votes (language regions ≠ canton canon).
        #expect(RadioListenerCores.regional(countryCode: "CH", regionName: "Zürich") == nil)
    }

    @Test func foldingAndJoins() {
        #expect(RadioCoreResolve.foldKey("Ö 3") == "o3")
        #expect(RadioCoreResolve.foldKey("88.6 - so rockt das Leben") == "886sorocktdasleben")
        #expect(RadioCoreResolve.tokens("R.SH Radio Schleswig-Holstein") == ["r", "sh", "radio", "schleswig", "holstein"])
        let joins = RadioCoreResolve.joins(["orf", "hitradio", "o3"])
        #expect(joins.contains("o3") && joins.contains("orfhitradioo3") && joins.contains("hitradioo3"))
        #expect(!joins.contains("orfo3"))   // contiguous only
    }

    @Test func resolveLadderOnRealCatalogShapes() {
        let pool = [
            rb("bayern1", "Bayern 1 Oberbayern", votes: 4358),
            rb("bayern1f", "Bayern 1 Franken", votes: 400),
            rb("wien", "ORF Radio Wien", votes: 300, cc: "AT"),
            rb("oe3", "ORF Hitradio Ö3", votes: 2000, cc: "AT"),
            rb("oe1", "Ö1 | ORF | HQ", votes: 900, cc: "AT"),
            rb("pilatus", "Radio Pilatus", votes: 500, cc: "CH"),
            rb("r24", "Radio24", votes: 400, cc: "CH"),
            rb("fm4", "FM4 | ORF", votes: 800, cc: "AT"),
            rb("swr4bw", "SWR4 BW [48 aac]", votes: 60),
            rb("ant1", "antenne 1", votes: 90),
            rb("rshlive", "R.SH Live", votes: 283),
            rb("diggi", "1LIVE Diggi", votes: 700),
            rb("einslive", "1LIVE", votes: 5000),
        ]
        // Rule 3: core key as contiguous join of the catalog name.
        let de = RadioCoreResolve.resolve(
            core: ["BAYERN 1", "SWR4 BW", "Hitradio antenne 1", "1LIVE",
                   "R.SH Radio Schleswig-Holstein"],
            pool: pool, countryCode: "DE")
        #expect(de.stations.map(\.name) == ["Bayern 1 Oberbayern", "SWR4 BW [48 aac]",
                                            "antenne 1", "1LIVE", "R.SH Live"])
        #expect(de.misses.isEmpty)
        let at = RadioCoreResolve.resolve(
            core: ["Ö 3", "Österreich 1", "Radio Wien", "FM4"],
            pool: pool, countryCode: "AT")
        #expect(at.stations.map(\.name) == ["ORF Hitradio Ö3", "Ö1 | ORF | HQ",
                                            "ORF Radio Wien", "FM4 | ORF"])
        let ch = RadioCoreResolve.resolve(
            core: ["Pilatus", "Radio 24"], pool: pool, countryCode: "CH")
        #expect(ch.stations.map(\.name) == ["Radio Pilatus", "Radio24"])
        // "1LIVE" must take the exact match, never the Diggi sub-brand.
        // Misses are returned, not swallowed.
        let miss = RadioCoreResolve.resolve(core: ["Bayern Funkpaket"], pool: pool, countryCode: "DE")
        #expect(miss.stations.isEmpty && miss.misses == ["Bayern Funkpaket"])
        // Proximity beats votes within rule 3: the survey's ASCII " - "
        // claim tail is cut, and "radio 88.6" (1978-vote sub-brand "88.6
        // Hard Rock" sits beside it) wins by closeness.
        let vienna = RadioCoreResolve.resolve(
            core: ["88.6 - so rockt das Leben"],
            pool: [rb("hardrock", "88.6 Hard Rock", votes: 1978, cc: "AT"),
                   rb("r886", "radio 88.6", votes: 1450, cc: "AT")],
            countryCode: "AT")
        #expect(vienna.stations.map(\.name) == ["radio 88.6"])
    }

    @Test func wikidataCoresAreWellFormedAndProbePlausibly() {
        // Abnahme: UK/FR cores lead with the public broadcaster.
        let gb = RadioWikidataCores.national(countryCode: "GB") ?? []
        #expect(gb.prefix(5).allSatisfy { $0.contains("BBC") })
        let fr = RadioWikidataCores.national(countryCode: "FR") ?? []
        #expect(fr.prefix(6).filter { $0.contains("France") || $0 == "FIP" }.count >= 4)
        for (code, table) in RadioWikidataCores.tables {
            #expect(!table.isEmpty && Set(table).count == table.count, "\(code) dupes")
        }
        // First-hand countries stay OUT of the generated table. The
        // priority place decides, the data never carries both.
        for code in ["DE", "AT", "CH"] {
            #expect(RadioWikidataCores.tables[code] == nil)
        }
    }

    @Test func lookupQueriesCoverTheReferenceMisses() {
        // "R.SH" (prefix before the Radio tail) found R.SH Live in the run;
        // "DAS HITRADIO" (leading number dropped) finds the Aachen station.
        #expect(RadioCoreResolve.lookupQueries("R.SH Radio Schleswig-Holstein", countryCode: "DE")
            .contains("R.SH"))
        #expect(RadioCoreResolve.lookupQueries("100,5 DAS HITRADIO.", countryCode: "DE")
            .contains("DAS HITRADIO"))
        #expect(RadioCoreResolve.lookupQueries("SWR1 RP", countryCode: "DE")
            .contains("SWR1 Rheinland-Pfalz"))
    }

    @Test func composeWithCoreKeepsHeadStableAndFillDiscoverable() {
        let core = (1...10).map { rb("core\($0)", "Core \($0)", votes: 10) }
        let votes = (1...20).map { rb("vote\($0)", "Vote \($0)", votes: 1000 - $0) }
        var headSeen = Set<String>()
        var tails = Set<String>()
        for day in 1...14 {
            let seed = RadioRotation.seed(day: 20_260_800 + day, countryCode: "DE")
            let row = RadioRotation.composeWithCore(
                core: core, votes: votes, clicktrend: [], seed: seed, limit: 12)
            #expect(row.count == 12)
            #expect(Set(row.map(\.id)).count == 12)   // no dupes
            // Head: the core's published top 3, EVERY day.
            headSeen.insert(row.prefix(3).map(\.id).joined(separator: ","))
            // Core pot: exactly limit - fillMinimum seats.
            let coreSeats = row.filter { $0.id.hasPrefix("radio:rb:core") }.count
            #expect(coreSeats == 12 - RadioRotation.fillMinimum)
            tails.insert(row.dropFirst(3).map(\.id).joined(separator: ","))
        }
        #expect(headSeen == ["radio:rb:core1,radio:rb:core2,radio:rb:core3"])
        #expect(tails.count > 1)   // rotation actually rotates within pots
        // Without a core the call is EXACTLY the coreless composition.
        let seed = RadioRotation.seed(day: 20_260_801, countryCode: "DE")
        #expect(RadioRotation.composeWithCore(core: [], votes: votes, clicktrend: [],
                                              seed: seed, limit: 12).map(\.id)
            == RadioRotation.compose(votes: votes, clicktrend: [], seed: seed, limit: 12).map(\.id))
        // A short core fills the row from votes, no seat lost.
        let short = RadioRotation.composeWithCore(
            core: Array(core.prefix(2)), votes: votes, clicktrend: [], seed: seed, limit: 12)
        #expect(short.count == 12 && short[0].id == "radio:rb:core1")
    }
}

// MARK: - National- und Regional-Wahl sind entkoppelt

struct RadioCountryDecouplingTests {
    @Test("ohne eigene National-Wahl gilt die geteilte Kaskade (Migration ohne Sprung)")
    func migrationKeepsTodaysBehaviour() {
        // Niemand hat entkoppelt: National folgt dem gemeinsamen Wert.
        // Exakt das heutige Verhalten, ohne dass etwas geschrieben wird.
        #expect(RadioCountryCascade.nationalCode(explicitNational: nil, shared: "DE") == "DE")
        #expect(RadioCountryCascade.nationalCode(explicitNational: "", shared: "DE") == "DE")
        #expect(RadioCountryCascade.nationalCode(explicitNational: nil, shared: nil) == nil)
    }

    @Test("National CH und Region NRW gleichzeitig")
    func nationalAndRegionAreIndependent() {
        // Die Region impliziert DE (NRW), die National-Wahl ist CH.
        let shared = RadioCountryCascade.effectiveCode(explicit: nil, regionImplied: "DE",
                                                       locale: "DE")
        #expect(shared == "DE")                                   // Region-Reihe
        #expect(RadioCountryCascade.nationalCode(explicitNational: "CH", shared: shared) == "CH")
        // Und die Kerne folgen je Reihe ihrem Land.
        #expect(RadioListenerCores.national(countryCode: "CH")
                == RadioListenerCores.switzerlandNational)
        #expect(RadioListenerCores.regional(countryCode: "DE",
                                            regionName: "Nordrhein-Westfalen") != nil)
    }
}

// MARK: - EINE Session-Titel-Quelle fuer den laufenden Track

struct NowPlayingTitleSourceTests {
    /// Der Zaun in Textform (die Flaechen selbst brauchen eine Session):
    /// keine Now-Playing-Flaeche darf den laufenden Titel aus der
    /// ITEM-Aufloesung nehmen. Die liefert fuer Katalog-Kennungen einen
    /// Stub mit Platzhalter, und genau so trug die Mini-Leiste einen
    /// Platzhalternamen, waehrend der grosse Player recht hatte.
    @Test("Now-Playing-Flaechen lesen den Titel aus der Session, nicht vom Item", .needsTheSources)
    func surfacesReadTheSessionTitle() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
        for name in ["Sources/Views/MiniPlayerBar.swift", "Sources/Views/DriveModeView.swift"] {
            let text = try String(contentsOf: root.appendingPathComponent(name), encoding: .utf8)
            #expect(text.contains("nowPlayingTitle"), "\(name) liest die Session nicht")
            // Nur die ANZEIGE ist gemeint: `activeItem.title` bleibt dort
            // richtig, wo der Sender-NAME gebraucht wird (Artwork-Initialen).
            // Deshalb prueft der Zaun Text(...)-Zeilen, nicht jede
            // Verwendung. Die Praezisierung kam aus einem Fehlschlag genau
            // dieser Art.
            for line in text.split(separator: "\n") where line.contains("Text(") {
                let collapsed = line.replacingOccurrences(of: " ", with: "")
                #expect(!collapsed.contains("Text(item.title)"), "\(name): \(line)")
                #expect(!collapsed.contains("Text(coordinator.activeItem?.title"), "\(name): \(line)")
            }
        }
    }
}

// MARK: - Das Tor kennt die Zielgroesse (EINE Stelle)

struct RadioGateTargetSizeTests {
    @Test("die Anforderung folgt der Flaeche, gedeckelt vom strengen Default")
    func requirementFollowsTheSurface() {
        // Ohne Zielgroesse: unveraendert streng.
        #expect(RadioFaviconGate.required(targetSide: nil) == RadioFaviconGate.minSide)
        // Eine WINZIGE Flaeche darf weniger verlangen …
        #expect(RadioFaviconGate.required(targetSide: 16, scale: 3) == 48)
        // … eine grosse aber NIE mehr als die allgemeine Regel (Deckel):
        #expect(RadioFaviconGate.required(targetSide: 128, scale: 3) == RadioFaviconGate.minSide)
        #expect(RadioFaviconGate.required(targetSide: 64, scale: 3) == RadioFaviconGate.minSide)
        // Und das Tor selbst nutzt genau diese Anforderung.
        #expect(RadioFaviconGate.acceptable(pixelWidth: 50, pixelHeight: 50, targetSide: 16))
        #expect(!RadioFaviconGate.acceptable(pixelWidth: 50, pixelHeight: 50))
    }
}
/// Die Augenbraue ueber dem Sendernamen: nur was wir in der Sprache des
/// Lesers BENENNEN koennen, steht dort. Der rohe erste Tag war
/// englisch und in der Sorte gemischt (MUSIC/ARD/MOSCOW) und stand in
/// der Nachrichten-Reihe als "MUSIC" da, also aktiv falsch.
struct RadioEyebrowTests {
    @Test("nur benennbare Kategorien erscheinen")
    func onlyNameableTagsPass() {
        #expect(RadioCatalog.eyebrow(forTags: ["news", "ard"]) == String(localized: "News"))
        #expect(RadioCatalog.eyebrow(forTags: ["  JAZZ "]) == String(localized: "Jazz"))
        // Sendernetz, Ort, Unbekanntes: die Zeile schweigt lieber.
        #expect(RadioCatalog.eyebrow(forTags: ["ard"]) == nil)
        #expect(RadioCatalog.eyebrow(forTags: ["moscow"]) == nil)
        #expect(RadioCatalog.eyebrow(forTags: []) == nil)
        // Die erste BENENNBARE gewinnt, nicht die erste ueberhaupt.
        #expect(RadioCatalog.eyebrow(forTags: ["moscow", "rock"]) == String(localized: "Rock"))
    }
}
