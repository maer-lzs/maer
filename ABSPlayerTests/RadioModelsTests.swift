// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

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

        // eb10440: the genre query rides the SEARCH endpoint — measured
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

        // Tag with a space rides the query, not the path — no escaping needed.
        let spaced = RadioBrowserClient.Query.byTag(tag: "hip hop", countryCode: nil, limit: 40)
        #expect(!spaced.path.contains(" "))
        #expect(params(spaced)["tag"] == "hip hop")

        let narrowed = RadioBrowserClient.Query.byTag(tag: "news", countryCode: "ch", limit: 40)
        #expect(params(narrowed)["countrycode"] == "CH")

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

@Test("Radio on Home gates on active source AND non-empty recents")
func radioHomeSectionGating() {
    #expect(RadioHomePresentation.showsSection(radioActive: true, recentsCount: 3))
    #expect(!RadioHomePresentation.showsSection(radioActive: true, recentsCount: 0))
    #expect(!RadioHomePresentation.showsSection(radioActive: false, recentsCount: 3))
    #expect(!RadioHomePresentation.showsSection(radioActive: false, recentsCount: 0))
}


@Test("mirror loop propagates cancellation instead of walking all mirrors")
func radioBrowserCancellationPropagates() async {
    let task = Task {
        // Deterministic: cancel ourselves BEFORE the call — the loop's
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
        // A truly foreign stream announces itself — this is the loud line.
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

    @Test("e4bd910: logo chain pure pieces — conservative entity match, P154, touch icon")
    func logoLookup() throws {
        // Conservative Wikidata match: label must fold-contain the name.
        let search = Data("""
        {"search":[{"id":"Q999","label":"Rock am Ring"},{"id":"Q42","label":"ROCK ANTENNE"}]}
        """.utf8)
        #expect(RadioLogoLookup.matchedEntityId(fromSearchData: search, stationName: "Rock Antenne") == "Q42")
        #expect(RadioLogoLookup.matchedEntityId(fromSearchData: search, stationName: "Deutschlandfunk") == nil)
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
        let search90 = Data("""
        {"search":[{"id":"Q105475115","label":"90s90s"}]}
        """.utf8)
        #expect(RadioLogoLookup.matchedEntityId(fromSearchData: search90,
                                                stationName: "90s90s Dance HQ") == "Q105475115")
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
        // the loser rides as a detail variant.
        let rock = deduped.first { PodcastSubscriptions.feedHost($0.homepage ?? "") == "rockantenne.de" }
        #expect(deduped.count == 4)
        #expect(rock?.id == "2")
        #expect(rock?.variants?.count == 1)
        // The same-named FOREIGN station (other domain) stays separate…
        #expect(deduped.contains { $0.id == "3" })
        // …and program siblings never fold (name differs).
        #expect(deduped.contains { $0.id == "4" } && deduped.contains { $0.id == "5" })
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
        // anyway — stale beats blank — and replaced by the fresh composition).
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
        // Without these two the logo chain has NO first stage — the second
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
        // The Italian entry goes even though its bitrate is the best — in a
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

// MARK: - 19a8b4c: first-hand listener cores

/// The resolve ladder is fixture-tested against REAL catalog names from the
/// reference run (2026-08-15, de1.api.radio-browser.info) — every fixture
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
        // Priority chain (72d233f (4)): countries without a survey fall to
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
        // Every regional core key must resolve through the canon — a typo in
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
        // Abnahme (72d233f): UK/FR cores lead with the public broadcaster.
        let gb = RadioWikidataCores.national(countryCode: "GB") ?? []
        #expect(gb.prefix(5).allSatisfy { $0.contains("BBC") })
        let fr = RadioWikidataCores.national(countryCode: "FR") ?? []
        #expect(fr.prefix(6).filter { $0.contains("France") || $0 == "FIP" }.count >= 4)
        for (code, table) in RadioWikidataCores.tables {
            #expect(!table.isEmpty && Set(table).count == table.count, "\(code) dupes")
        }
        // First-hand countries stay OUT of the generated table — the
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

// MARK: - P12: National- und Regional-Wahl sind entkoppelt

struct RadioCountryDecouplingTests {
    @Test("ohne eigene National-Wahl gilt die geteilte Kaskade (Migration ohne Sprung)")
    func migrationKeepsTodaysBehaviour() {
        // Niemand hat entkoppelt: National folgt dem gemeinsamen Wert —
        // exakt das heutige Verhalten, ohne dass etwas geschrieben wird.
        #expect(RadioCountryCascade.nationalCode(explicitNational: nil, shared: "DE") == "DE")
        #expect(RadioCountryCascade.nationalCode(explicitNational: "", shared: "DE") == "DE")
        #expect(RadioCountryCascade.nationalCode(explicitNational: nil, shared: nil) == nil)
    }

    @Test("the owner's Fall: National CH, Region NRW gleichzeitig")
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

// MARK: - f0e7f4e: EINE Session-Titel-Quelle fuer den laufenden Track

struct NowPlayingTitleSourceTests {
    /// Der Zaun in Textform (die Flaechen selbst brauchen eine Session):
    /// keine Now-Playing-Flaeche darf den laufenden Titel aus der
    /// ITEM-Aufloesung nehmen — die liefert fuer Katalog-Kennungen einen
    /// Stub mit Platzhalter, und genau so sagte die Mini-Leiste
    /// „Unbekannter Titel", waehrend der grosse Player recht hatte.
    @Test("Now-Playing-Flaechen lesen den Titel aus der Session, nicht vom Item")
    func surfacesReadTheSessionTitle() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
        for name in ["Sources/Views/MiniPlayerBar.swift", "Sources/Views/DriveModeView.swift"] {
            let text = try String(contentsOf: root.appendingPathComponent(name), encoding: .utf8)
            #expect(text.contains("nowPlayingTitle"), "\(name) liest die Session nicht")
            // Nur die ANZEIGE ist gemeint: `activeItem.title` bleibt dort
            // richtig, wo der Sender-NAME gebraucht wird (Artwork-Initialen)
            // — deshalb prueft der Zaun Text(...)-Zeilen, nicht jede
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

// MARK: - 10eb85f: das Tor kennt die Zielgroesse (EINE Stelle)

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
