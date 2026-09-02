// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// The AntennaPod decoder on rows with the values measured on the
/// schema fixture (AntennaPod 3.12.0, database version 3110000), and the
/// SQLite reader on that fixture file itself.
struct AntennaPodDatabaseTests {
    private let dlf = AntennaPodDatabase.Feed(id: 1, title: "Das war der Tag",
                                              downloadURL: "https://www.deutschlandfunk.de/das-war-der-tag-102.xml", state: 0)
    private let gone = AntennaPodDatabase.Feed(id: 9, title: "Left", downloadURL: "https://left.example/rss", state: 1)

    private func item(_ id: Int64, feed: Int64 = 1, read: Int64, guid: String? = "guid") -> AntennaPodDatabase.Item {
        AntennaPodDatabase.Item(id: id, feedID: feed, title: "Episode \(id)", identifier: guid,
                                link: "https://www.deutschlandfunk.de/e\(id).html", read: read)
    }

    private func media(_ item: Int64, duration: Int64 = 2_798_000, position: Int64 = 0,
                       lastPlayed: Int64 = 0, completion: Int64 = 0) -> AntennaPodDatabase.Media {
        AntennaPodDatabase.Media(itemID: item, durationMs: duration, positionMs: position,
                                 lastPlayedMs: lastPlayed, completionMs: completion,
                                 downloadURL: "https://podcast-mp3.dradio.de/\(item).mp3?refId=x")
    }

    @Test("angefangen: Position und Dauer aus Millisekunden, Zeitpunkt = zuletzt gespielt")
    func started() throws {
        let lib = AntennaPodDatabase.library(
            feeds: [dlf], items: [item(1, read: 0, guid: "7f619668")],
            media: [media(1, position: 930_000, lastPlayed: 1_756_751_400_000, completion: 1_756_751_400_000)])
        #expect(lib.feedURLs == [dlf.downloadURL!])
        let s = try #require(lib.states.first)
        #expect(s.episodeGUID == "7f619668")
        #expect(s.position == 930)
        #expect(s.duration == 2798)
        #expect(s.finished == false)
        #expect(s.stampedAt == 1_756_751_400_000)
        #expect(s.enclosureURL?.hasPrefix("https://podcast-mp3.dradio.de/1.mp3") == true)
        #expect(s.episodeLink == "https://www.deutschlandfunk.de/e1.html")
    }

    @Test("gehoert: read=1 mit Abschlusszeitpunkt")
    func played() {
        let lib = AntennaPodDatabase.library(
            feeds: [dlf], items: [item(2, read: 1)],
            media: [media(2, duration: 2_802_000, lastPlayed: 1_756_665_600_000, completion: 1_756_665_600_000)])
        #expect(lib.states.count == 1)
        #expect(lib.states.first?.finished == true)
        #expect(lib.states.first?.position == 0)
        #expect(lib.states.first?.stampedAt == 1_756_665_600_000)
    }

    @Test("von Hand markiert: gehoert ohne Zeitpunkt, darf nur fuellen")
    func markedByHand() {
        let lib = AntennaPodDatabase.library(feeds: [dlf], items: [item(7, read: 1)], media: [media(7)])
        #expect(lib.states.first?.finished == true)
        #expect(lib.states.first?.stampedAt == nil)
    }

    @Test("neu und ungehoert ohne Position sind kein Stand")
    func unplayedIsNoState() {
        let lib = AntennaPodDatabase.library(
            feeds: [dlf], items: [item(3, read: -1), item(4, read: 0)], media: [media(3), media(4, position: 500)])
        #expect(lib.states.isEmpty)
    }

    @Test("eine abbestellte Sendung bleibt mit ihren Folgen draussen; ohne Spalte gilt abonniert")
    func unsubscribedStaysOut() {
        let lib = AntennaPodDatabase.library(
            feeds: [dlf, gone], items: [item(5, feed: 9, read: 1)], media: [media(5, lastPlayed: 5)])
        #expect(lib.feedURLs == [dlf.downloadURL!])
        #expect(lib.states.isEmpty)
        var old = gone; old.state = nil
        #expect(AntennaPodDatabase.library(feeds: [old], items: [], media: []).feedURLs == [gone.downloadURL!])
    }

    @Test("ein Eintrag ohne Medienzeile: gehoert zaehlt, angefangen kann es nicht sein")
    func withoutMedia() {
        let lib = AntennaPodDatabase.library(feeds: [dlf], items: [item(6, read: 1), item(8, read: 0)], media: [])
        #expect(lib.states.map(\.finished) == [true])
        #expect(lib.states.first?.enclosureURL == nil)
    }

    /// The schema fixture built from AntennaPod 3.12.0, read through the
    /// real SQLite path: two feeds, five states out of seven episodes.
    @Test("die Schema-Datei liest sich durch den SQLite-Leser")
    func fixtureFile() throws {
        let data = try CorpusFixture.data("antennapod", ext: "db", subdirectory: "AntennaPod")
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("antennapod-\(UUID().uuidString).db")
        try data.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let lib = try #require(PodcastImport.readAntennaPodDatabase(at: url))
        #expect(lib.feedURLs == ["https://www.deutschlandfunk.de/das-war-der-tag-102.xml",
                                 "https://www1.wdr.de/mediathek/audio/zeitzeichen/zeitzeichen-podcast-100.podcast"])
        #expect(lib.states.count == 5)
        #expect(lib.states.filter(\.finished).count == 3)
        #expect(lib.states.filter { $0.stampedAt == nil }.count == 1)
        let started = lib.states.filter { !$0.finished }
        #expect(started.map(\.position).sorted() == [312, 930])
        #expect(lib.states.allSatisfy { $0.episodeGUID != nil && $0.enclosureURL != nil })
        // Not a database at all: nil, never an empty success.
        let junk = url.deletingLastPathComponent().appendingPathComponent("junk-\(UUID().uuidString).db")
        try Data("not sqlite".utf8).write(to: junk)
        defer { try? FileManager.default.removeItem(at: junk) }
        #expect(PodcastImport.readAntennaPodDatabase(at: junk) == nil)
    }
}
#endif
