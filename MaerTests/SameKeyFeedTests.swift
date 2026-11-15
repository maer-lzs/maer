// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// Two addresses can share a feed key (the key reads the address in small
/// letters and keeps ten query names). A second feed under a held key is
/// not merged into the held show: the merge took the fresh title and
/// address, and the held feed was fetched no more.
@MainActor
struct SameKeyFeedTests {
    private static func show(_ address: String, title: String, guids: [String]) -> PodcastShow {
        let key = PodcastIdentity.feedKey(address)
        return PodcastShow(id: "feed:\(key)", title: title, author: nil, artworkURL: nil, description: nil,
                           feedURL: address,
                           episodes: guids.enumerated().map { index, guid in
                               PodcastEpisode(guid: "rss:\(key):\(guid)", title: "\(title) \(index)",
                                              audioURL: "https://cdn.example/\(guid).mp3",
                                              pubDate: Double(index + 1), duration: 60)
                           })
    }

    /// A store holding `held`; the next fetch answers with `fresh`.
    private static func store(holding held: PodcastShow, answering fresh: PodcastShow) async throws
        -> (PodcastSubscriptions, () -> Void) {
        let (subs, cleanup) = try await BulkImportTests.store()
        subs._testFeedFetcher = { _ in .show(held) }
        try #require(await subs.subscribe(urlString: held.feedURL, notesCloud: false))
        subs._testFeedFetcher = { _ in .show(fresh) }
        return (subs, cleanup)
    }

    struct Case: Sendable, CustomTestStringConvertible {
        let name: String
        let held: String
        let fresh: String
        let heldGuids: [String]
        let freshGuids: [String]
        let keptApart: Bool
        var testDescription: String { name }
    }

    nonisolated static let run = UUID().uuidString.prefix(8)
    nonisolated static let cases: [Case] = [
        Case(name: "the path in another case, other episodes", held: "https://same-key.example/\(run)/Show.xml",
             fresh: "https://same-key.example/\(run)/show.xml", heldGuids: ["a1", "a2"], freshGuids: ["b1", "b2"],
             keptApart: true),
        Case(name: "another parameter outside the ten names, other episodes",
             held: "https://same-key.example/\(run)/feed.xml?edition=north",
             fresh: "https://same-key.example/\(run)/feed.xml?edition=south", heldGuids: ["n1"], freshGuids: ["s1"],
             keptApart: true),
        Case(name: "http against https, the same episodes", held: "https://same-key.example/\(run)/plain.xml",
             fresh: "http://same-key.example/\(run)/plain.xml", heldGuids: ["p1", "p2"], freshGuids: ["p2", "p3"],
             keptApart: false),
        Case(name: "the same address twice", held: "https://same-key.example/\(run)/twice.xml",
             fresh: "https://same-key.example/\(run)/twice.xml", heldGuids: ["t1"], freshGuids: ["t1", "t2"],
             keptApart: false),
        Case(name: "the held show has no episodes, the parse has: it takes the parse",
             held: "https://same-key.example/\(run)/Expired.xml", fresh: "https://same-key.example/\(run)/expired.xml",
             heldGuids: [], freshGuids: ["f1", "f2"], keptApart: false),
        Case(name: "the path in another case, an episode in common", held: "https://same-key.example/\(run)/Mixed.xml",
             fresh: "https://same-key.example/\(run)/mixed.xml", heldGuids: ["m1", "m2"], freshGuids: ["m2", "m3"],
             keptApart: false),
    ]

    @Test("a second address under a held key: another feed is kept apart, the same feed is merged as before",
          arguments: cases)
    func aSecondAddressUnderAHeldKey(_ c: Case) async throws {
        let held = Self.show(c.held, title: "Held", guids: c.heldGuids)
        let fresh = Self.show(c.fresh, title: "Arrived", guids: c.freshGuids)
        #expect(held.id == fresh.id, "the case does not share a key")
        let (subs, cleanup) = try await Self.store(holding: held, answering: fresh)
        defer { cleanup() }
        let before = subs.shows
        let outcome = await subs.follow(urlString: c.fresh, notesCloud: false)
        let stored = try #require(subs.shows.first { $0.id == held.id })
        #expect(subs.shows.count == 1, "a second subscription was made")
        if c.keptApart {
            #expect(outcome == .keptApart(title: "Held"))
            #expect(subs.shows == before, "the held show was changed: \(stored.title) \(stored.feedURL)")
        } else {
            #expect(outcome.isHeld && stored.title == "Arrived", "the same feed was not merged as before")
        }
    }

    @Test("another address and no episodes to compare: nothing said, title and address stay")
    func anEmptyParseTellsNothing() async throws {
        let held = Self.show("https://same-key.example/\(Self.run)/Empty.xml", title: "Held", guids: ["e1"])
        let fresh = Self.show("https://same-key.example/\(Self.run)/empty.xml", title: "Arrived", guids: [])
        let (subs, cleanup) = try await Self.store(holding: held, answering: fresh)
        defer { cleanup() }
        #expect(PodcastIdentity.sameKey(stored: held, fresh: fresh) == .unknown)
        let emptyHeld = Self.show(held.feedURL, title: "Held", guids: [])
        #expect(PodcastIdentity.sameKey(stored: emptyHeld, fresh: fresh) == .unknown, "two empty sides tell nothing")
        _ = await subs.follow(urlString: fresh.feedURL, notesCloud: false)
        let stored = try #require(subs.shows.first { $0.id == held.id })
        #expect(stored.title == "Held" && stored.feedURL == held.feedURL)
    }

    @Test("the person's tap hears the sentence with the held show's name; a mechanism and an import do not, and nothing changes the held show")
    func whoHearsIt() async throws {
        let held = Self.show("https://same-key.example/\(Self.run)/Door.xml", title: "Held", guids: ["d1"])
        let fresh = Self.show("https://same-key.example/\(Self.run)/door.xml", title: "Arrived", guids: ["x1"])
        let (subs, cleanup) = try await Self.store(holding: held, answering: fresh)
        defer { cleanup() }
        let before = subs.shows
        let tap = SubscribeTap.local(await subs.subscribeUnlessOnServer(urlString: fresh.feedURL, notesCloud: false))
        #expect(tap == .failed(sentence: PodcastSubscriptions.keptApartSentence("Held")))
        #expect(PodcastSubscriptions.keptApartSentence("Held").contains("Held"))
        let mechanism = await subs.subscribeUnlessOnServer(urlString: fresh.feedURL, notesCloud: false,
                                                           isSingleUserAct: false)
        #expect(mechanism == .keptApart(title: "Held"))
        // The import fetches no held key: it counts it as followed.
        let result = await subs.importForeignLibrary(ForeignLibrary(feedURLs: [fresh.feedURL], states: []))
        #expect(result.alreadySubscribed == 1 && result.subscribed == 0, "the import's summary counts it otherwise")
        // A fetch for one episode folds nothing of another feed in.
        #expect(await subs.absorb(fresh, showId: held.id) == nil)
        #expect(subs.shows == before, "an entry changed the held show")
    }

    @Test("the address as written: no scheme, no www, the host small, the path in its case, counting parameters gone, sorted")
    func theStrictAddress() {
        #expect(PodcastIdentity.strictAddress("https://www.Example.com/Feed/Show.xml/")
                == PodcastIdentity.strictAddress("http://example.com/Feed/Show.xml"))
        #expect(PodcastIdentity.strictAddress("https://example.com/Feed.xml")
                != PodcastIdentity.strictAddress("https://example.com/feed.xml"))
        #expect(PodcastIdentity.strictAddress("https://example.com/f.xml?b=2&utm_source=x&a=1&fbclid=y#top")
                == "example.com/f.xml?a=1&b=2")
        #expect(PodcastIdentity.strictAddress("example.com/f.xml") == "example.com/f.xml")
    }
}
#endif
