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
                            bitrate: bitrate, codec: codec, votes: nil)
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
        // DE list it must never become the default (the owner's report).
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
