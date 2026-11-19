// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// A link opens by what it carries, not by what the opening device knows of
/// the feed; the device's sign-in never travels with it.
@MainActor
struct SharedLinkOpensTests {
    static let feed = SharedLinkOpenerTests.feed

    private func link(_ content: SharedLink.Content) throws -> URL {
        try #require(SharedLink.url(for: content))
    }

    @Test("a link opens what it carries: a public feed's episode and show, a station, a catalog book; access in an address or a song address does not")
    func theLinkCarriesTheAnswer() {
        #expect(SharedLink.opens(.episode(feedURL: Self.feed, guid: "g", .init())))
        #expect(SharedLink.opens(.show(feedURL: Self.feed, .init())))
        #expect(SharedLink.opens(.station(uuid: SharedLinkOpenerTests.uuid, .init())))
        #expect(SharedLink.opens(.book(itemId: "lv:1234", .init())))
        #expect(!SharedLink.opens(.show(feedURL: Self.feed + "?auth=x", .init())), "a feed with access in its address opened")
        #expect(!SharedLink.opens(.episode(feedURL: Self.feed, guid: "g",
                                           .init(audioURL: "https://cdn.example.org/a.mp3?token=s3cr3t"))))
        #expect(!SharedLink.opens(.book(itemId: "lva:album#2", .init())), "a song address opened as a book")
    }

    @Test("a feed this device keeps at home (a premium mark, a sign-in it cannot read now) opens from a link like any public feed")
    func whatTheDeviceKnowsDoesNotRefuse() async throws {
        // The open has no question to the device left (the fence below):
        // the same link opens the same on every device.
        let ways = SharedLinkOpenerTests.Ways()
        let episode = SharedLink.episodeId(feedURL: Self.feed, guid: "g")
        ways.known = [episode]
        #expect(await ways.opener().outcome(for: try link(.episode(feedURL: Self.feed, guid: "g", .init())))
                    == .episode(itemId: episode), "the device's own state refused the link")
        #expect(await ways.opener().outcome(for: try link(.show(feedURL: Self.feed, .init()))) == .show(feedURL: Self.feed))
    }

    @Test("sharing still keeps a feed at home that stays home on this device")
    func theShareButtonKeepsItsLock() {
        #expect(!SharedLink.offers(.show(feedURL: Self.feed, .init()), staysHome: { _ in true }))
        #expect(SharedLink.offers(.show(feedURL: Self.feed, .init()), staysHome: { _ in false }))
    }

    @Test("a feed that asks for a sign-in says so in its own sentence instead of an empty page")
    func aSignInSaysItsSentence() async throws {
        let ways = SharedLinkOpenerTests.Ways()
        ways.asksSignIn = [Self.feed]
        let outcome = await ways.opener().outcome(for: try link(.episode(feedURL: Self.feed, guid: "g", .init())))
        #expect(outcome == .refused(reason: "signIn"), "a feed that asks for a sign-in opened \(outcome)")
        let sentence = try #require(SharedLinkOpener.sentence(for: outcome))
        #expect(sentence != SharedLinkOpener.refusal, "a sign-in said the general refusal")
    }

    @Test("a request for a link carries nothing of this device and does not wait for an unreadable sign-in; every other request as before")
    func aLinkSendsNoAccess() {
        let present = PodcastFeedAuth.Access.present(user: "u", password: "p")
        #expect(PodcastFeedAuth.requestAccess(present, sendsAccess: false) == .none, "a link's request carried the sign-in")
        #expect(PodcastFeedAuth.requestAccess(.unknown, sendsAccess: false) == .none,
                "a link's request waited for an unreadable sign-in")
        #expect(PodcastFeedAuth.requestAccess(.absent, sendsAccess: false) == .none)
        #expect(PodcastFeedAuth.requestAccess(present, sendsAccess: true) == .header("Basic dTpw"))
        #expect(PodcastFeedAuth.requestAccess(.unknown, sendsAccess: true) == .wait)
        #expect(PodcastFeedAuth.requestAccess(.absent, sendsAccess: true) == .none)
    }

    @Test("the open asks no state of the device, and the link's read of a feed goes without its access", .needsTheSources)
    func theOpenerAsksOnlyTheLink() throws {
        let code = SyncContractFenceTests.stripped(
            try String(contentsOf: SourceTree.root.appendingPathComponent("Sources/ViewModels/SharedLinkOpener.swift"),
                       encoding: .utf8))
        let outcome = try #require(ABSPodcastRefreshTests.body(of: "func outcome(for url: URL)", in: code))
        #expect(outcome.contains("SharedLink.opens("), "the open does not ask the link's own rule")
        #expect(!outcome.contains("staysHome"), "the open asks what the device keeps at home")
        let live = try #require(ABSPodcastRefreshTests.body(of: "static func live(", in: code))
        #expect(!live.contains("PodcastSubscriptions.staysHome"), "the live open still asks the device")
        #expect(live.contains("sendsAccess: false"), "a link's read of a feed carries the device's access")
        let feeds = SyncContractFenceTests.stripped(
            try String(contentsOf: SourceTree.root.appendingPathComponent("Sources/Providers/PodcastSubscriptions.swift"),
                       encoding: .utf8))
        #expect(feeds.contains("PodcastFeedAuth.requestAccess("), "the feed request decides its header elsewhere")
    }
}
#endif
