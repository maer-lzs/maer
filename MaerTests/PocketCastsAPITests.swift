// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// The Pocket Casts decoder on the frozen forms under
/// `Fixtures/ForeignImport/pocketcasts-*.json`: the measured shapes with
/// fantasy values. The same files go to the source watch.
struct PocketCastsAPITests {
    private func fixture(_ name: String) throws -> Data {
        try CorpusFixture.data(name, ext: "json", subdirectory: "ForeignImport")
    }

    @Test("Anmeldung: Token oder der Grund der Ablehnung")
    func login() throws {
        #expect(PocketCastsAPI.token(from: try fixture("pocketcasts-login")) == "eyJhbGciOiJIUzI1NiJ9.fixture.token")
        let rejected = try fixture("pocketcasts-login-rejected")
        #expect(PocketCastsAPI.token(from: rejected) == nil)
        #expect(PocketCastsAPI.errorMessage(from: rejected) == "Email not found")
    }

    @Test("Bestand: Sendungen mit uuid, unbekannte Felder uebergangen")
    func podcasts() throws {
        let list = try #require(PocketCastsAPI.podcasts(from: try fixture("pocketcasts-list")))
        #expect(list.map(\.uuid) == ["aaaaaaaa-0000-4000-8000-000000000001", "aaaaaaaa-0000-4000-8000-000000000002"])
        #expect(list.first?.title == "Formula Why")
    }

    @Test("Staende: Status und Position je Folge, Zahlen auch als Text")
    func states() throws {
        let states = try #require(PocketCastsAPI.episodeStates(from: try fixture("pocketcasts-episodes")))
        #expect(states.count == 6)
        #expect(states[0].playingStatus == 2 && states[0].playedUpTo == 612 && states[0].duration == 2798)
        #expect(states[1].playingStatus == 3)
        // The archive: put away counts as finished, heard or not.
        #expect(states[4].isDeleted && states[4].finished && !states[4].inProgress)
        #expect(states[5].isDeleted && states[5].finished && !states[5].inProgress)
        #expect(!states[0].isDeleted && states[0].inProgress && !states[0].finished)
        #expect(!states[2].finished && !states[2].inProgress)
        let cached = try #require(PocketCastsAPI.cachedEpisodes(from: try fixture("pocketcasts-cache-full")))
        #expect(cached.count == 3)
        #expect(cached[0].title == "Why do tyres degrade?")
        #expect(cached[0].enclosureURL == "https://cdn.example.invalid/formula-why/11.mp3?modified=1")
        // The cache hands the duration as text on some rows.
        #expect(cached[1].duration == 2802)
    }

    @Test("Feed-Tuer: uuid auf Feed-Adresse")
    func feeds() throws {
        let feeds = try #require(PocketCastsAPI.feedURLs(from: try fixture("pocketcasts-feeds")))
        #expect(feeds == ["aaaaaaaa-0000-4000-8000-000000000001": "https://feeds.example.invalid/formula-why.rss"])
    }

    @Test("die Bibliothek: angefangen und gehoert mit Titel und Enclosure, ohne Zeitpunkt; ohne Feed zaehlt die Sendung als nicht importierbar")
    func library() throws {
        let podcasts = try #require(PocketCastsAPI.podcasts(from: try fixture("pocketcasts-list")))
        let feeds = try #require(PocketCastsAPI.feedURLs(from: try fixture("pocketcasts-feeds")))
        let states = try #require(PocketCastsAPI.episodeStates(from: try fixture("pocketcasts-episodes")))
        let cached = try #require(PocketCastsAPI.cachedEpisodes(from: try fixture("pocketcasts-cache-full")))
        let one = "aaaaaaaa-0000-4000-8000-000000000001"
        let lib = PocketCastsAPI.library(podcasts: podcasts, feedURLs: feeds,
                                         states: [one: states], episodes: [one: cached])
        #expect(lib.feedURLs == ["https://feeds.example.invalid/formula-why.rss"])
        #expect(lib.unimportablePaidCount == 1)
        // Unplayed (1) and "in progress" at zero are no state; the two
        // archived rows are finished states and carry the mark.
        #expect(lib.states.count == 4)
        #expect(lib.states.filter(\.archived).count == 2)
        #expect(lib.states.filter { $0.archived }.allSatisfy { $0.finished })
        #expect(lib.states.filter(\.finished).count == 3)
        let started = try #require(lib.states.first { !$0.finished })
        #expect(started.position == 612)
        #expect(started.episodeTitle == "Why do tyres degrade?")
        #expect(started.enclosureURL?.hasPrefix("https://cdn.example.invalid/formula-why/11.mp3") == true)
        #expect(started.duration == 2798)
        #expect(started.stampedAt == nil)
        #expect(started.feedURL == "https://feeds.example.invalid/formula-why.rss")
        let done = try #require(lib.states.first { $0.finished })
        #expect(done.episodeTitle == "What is DRS?")
        #expect(done.stampedAt == nil)
    }

    @Test("ohne Cache-Zeile bleibt der Stand, nur ohne Namen")
    func withoutCache() throws {
        let podcasts = try #require(PocketCastsAPI.podcasts(from: try fixture("pocketcasts-list")))
        let feeds = try #require(PocketCastsAPI.feedURLs(from: try fixture("pocketcasts-feeds")))
        let states = try #require(PocketCastsAPI.episodeStates(from: try fixture("pocketcasts-episodes")))
        let lib = PocketCastsAPI.library(podcasts: podcasts, feedURLs: feeds,
                                         states: ["aaaaaaaa-0000-4000-8000-000000000001": states], episodes: [:])
        #expect(lib.states.count == 4)
        #expect(lib.states.allSatisfy { $0.episodeTitle == nil && $0.enclosureURL == nil })
    }

    /// A state whose episode the show's cache does not carry is
    /// asked for by itself. The answer's shape is unverified until the
    /// probe; the decoder takes the measured cache form at the top level
    /// or under `episode`, and anything else is nil.
    @Test("Einzelabfrage: Titel, Adresse und Datum, oben oder unter episode; ohne uuid nil")
    func episodeDetail() throws {
        let detail = try #require(PocketCastsAPI.episodeDetail(from: try fixture("pocketcasts-episode")))
        #expect(detail.uuid == "eeeeeeee-0000-4000-8000-000000000099")
        #expect(detail.title == "The tyre that never was")
        #expect(detail.enclosureURL == "https://cdn.example.invalid/formula-why/99.mp3?modified=2")
        #expect(detail.published == "2019-03-04T05:06:07Z")
        let nested = try #require(PocketCastsAPI.episodeDetail(from: Data("{\"episode\":{\"uuid\":\"n1\",\"title\":\"Nested\"}}".utf8)))
        #expect(nested.title == "Nested" && nested.enclosureURL == nil)
        let bare = try #require(PocketCastsAPI.episodeDetail(from: Data("{\"uuid\":\"b1\",\"title\":\"\",\"url\":\"\"}".utf8)))
        #expect(bare.title == nil && bare.enclosureURL == nil)
        #expect(PocketCastsAPI.episodeDetail(from: Data("{\"title\":\"no id\"}".utf8)) == nil)
        #expect(PocketCastsAPI.episodeDetail(from: Data("[]".utf8)) == nil)
        #expect(PocketCastsAPI.episodeDetail(from: Data("<html>".utf8)) == nil)
    }

    @Test("die Bibliothek merkt sich, welche Staende ihren Griff aus der Einzelabfrage haben")
    func libraryMarksLookedUp() throws {
        let podcasts = try #require(PocketCastsAPI.podcasts(from: try fixture("pocketcasts-list")))
        let feeds = try #require(PocketCastsAPI.feedURLs(from: try fixture("pocketcasts-feeds")))
        let states = try #require(PocketCastsAPI.episodeStates(from: try fixture("pocketcasts-episodes")))
        let one = "aaaaaaaa-0000-4000-8000-000000000001"
        let asked = PocketCastsAPI.CachedEpisode(uuid: states[0].uuid, title: "Asked for", enclosureURL: "https://cdn.example.invalid/asked.mp3", duration: nil)
        let lib = PocketCastsAPI.library(podcasts: podcasts, feedURLs: feeds, states: [one: states],
                                         episodes: [one: [asked]], lookedUp: [states[0].uuid])
        let placed = try #require(lib.states.first { $0.episodeTitle == "Asked for" })
        #expect(placed.handleFromLookup)
        #expect(lib.states.filter(\.handleFromLookup).count == 1)
        #expect(lib.states.filter { !$0.handleFromLookup }.allSatisfy { $0.episodeTitle == nil })
    }

    @Test("Rot-Probe: gekipptes Pflichtfeld oder kaputtes JSON ergibt nil, nie einen Teil")
    func brokenAnswers() {
        #expect(PocketCastsAPI.podcasts(from: Data("{\"podcasts\":[{\"title\":\"no uuid\"}]}".utf8)) == nil)
        #expect(PocketCastsAPI.episodeStates(from: Data("{\"episodes\":[{\"uuid\":\"x\"}]}".utf8)) == nil)
        #expect(PocketCastsAPI.cachedEpisodes(from: Data("{\"podcast\":{}}".utf8)) == nil)
        #expect(PocketCastsAPI.feedURLs(from: Data("{\"status\":\"ok\"}".utf8)) == nil)
        #expect(PocketCastsAPI.token(from: Data("not json".utf8)) == nil)
        #expect(PocketCastsAPI.podcasts(from: Data("<html>captive portal</html>".utf8)) == nil)
    }
}
#endif
