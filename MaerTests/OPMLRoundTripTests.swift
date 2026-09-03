// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// The export writes what the one reader reads: a file of ours comes
/// back as the same stock, and a premium feed leaves with its states.
struct OPMLRoundTripTests {
    private let free = (title: "Free & Open", feedURL: "https://free.example/rss")
    private let premium = (title: "Paid", feedURL: "https://paid.example/rss?token=SECRET1")

    private func state(_ feed: String, guid: String, position: Double, finished: Bool = false,
                       at stamp: Double? = 1_706_781_600_500) -> ForeignListeningState {
        ForeignListeningState(feedURL: feed, episodeGUID: guid,
                              enclosureURL: "https://cdn.example/\(guid).mp3",
                              episodeLink: "https://free.example/episodes/\(guid)",
                              episodeTitle: "Episode <\(guid)> & more",
                              position: position, finished: finished, stampedAt: stamp)
    }

    @Test("Ausfuhr ⇒ Leser ⇒ identischer Bestand")
    func roundTrip() throws {
        var archived = state(free.feedURL, guid: "four", position: 0, finished: true)
        archived.archived = true
        let states = [
            state(free.feedURL, guid: "one", position: 600),
            state(free.feedURL, guid: "two", position: 0, finished: true),
            state(free.feedURL, guid: "three", position: 42, at: nil),
            archived,
        ]
        let doc = OPMLExport.document(shows: [free], states: states,
                                      generatedAt: Date(timeIntervalSince1970: 1_784_600_000))
        let back = try #require(OvercastOPML.parse(Data(doc.utf8)))
        #expect(back.feedURLs == [free.feedURL])
        #expect(back.states == states)
        // The moment survives to the millisecond, so a returning file
        // never looks newer or older than the stock it came from.
        #expect(back.states.first?.stampedAt == 1_706_781_600_500)
        // Archived goes out as `userDeleted` and comes back as archived AND finished.
        #expect(doc.contains(#"userDeleted="1""#))
        #expect(back.states[3].archived && back.states[3].finished)
        #expect(!back.states[0].archived)
    }

    @Test("ein Premium-Feed nimmt seine Staende mit aus der Datei")
    func premiumStatesLeaveWithTheirFeed() throws {
        let all = [state(free.feedURL, guid: "f", position: 100),
                   state(premium.feedURL, guid: "p", position: 200)]
        let split = OPMLExport.partition(shows: [free, premium], isPremium: { _ in false })
        #expect(split.excluded.map(\.title) == ["Paid"])
        let kept = OPMLExport.states(all, for: split.safe)
        #expect(kept.map(\.episodeGUID) == ["f"])
        let doc = OPMLExport.document(shows: split.safe, states: all,
                                      generatedAt: Date(timeIntervalSince1970: 0))
        // Even handed ALL states, the document writes only those of the
        // shows it carries.
        #expect(!doc.contains("SECRET1"))
        #expect(!doc.contains(#"guid="p""#))
        let back = try #require(OvercastOPML.parse(Data(doc.utf8)))
        #expect(back.states.map(\.episodeGUID) == ["f"])
    }

    @Test("ohne Staende bleibt die Datei das schlichte OPML")
    func plainWithoutStates() throws {
        let doc = OPMLExport.document(shows: [free], generatedAt: Date(timeIntervalSince1970: 0))
        #expect(doc.contains(#"xmlUrl="https://free.example/rss"/>"#))
        #expect(!doc.contains("podcast-episode"))
        let back = try #require(OvercastOPML.parse(Data(doc.utf8)))
        #expect(back.states.isEmpty)
        #expect(back.feedURLs == [free.feedURL])
    }
}
#endif
