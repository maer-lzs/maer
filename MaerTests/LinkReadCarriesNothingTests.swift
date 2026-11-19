// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// A link's read of a feed carries nothing of this device: no sign-in, no
/// headers it keeps for the server, no cookie. Measured at a host on the
/// loopback, with the device's read of the same feed as the control.
@MainActor
struct LinkReadCarriesNothingTests {
    static let feed = Data("<rss><channel><title>T</title></channel></rss>".utf8)

    @Test("a link's read sends no sign-in, no server header and no cookie; the device's own read of the same feed sends all three")
    func theReadCarriesNothing() async throws {
        let host = try HeaderRedirectMeasureTests.RecordingHost(body: Self.feed, contentType: "application/rss+xml")
        try await host.start()
        defer { host.stop() }
        let url = try #require(URL(string: "http://127.0.0.1:\(host.port)/feed-\(UUID().uuidString.prefix(8)).xml"))
        let key = PodcastIdentity.feedKey(url.absoluteString)
        let keys = ServerHeadersWayTests().headers(port: Int(host.port))
        let cookie = try #require(HTTPCookie(properties: [.domain: "127.0.0.1", .path: "/", .name: "maer-probe",
                                                          .value: "c-\(UUID().uuidString.prefix(6))", .originURL: url]))
        HTTPCookieStorage.shared.setCookie(cookie)
        defer { HTTPCookieStorage.shared.deleteCookie(cookie) }

        func read(sendsAccess: Bool) async throws -> String {
            let before = host.recorded.count
            try await PodcastFeedAuth.$reading.withValue(FeedAccessUnknownTests.keychain(key, .value("user\nsecret"))) {
                try await ServerHeaders.$witness.withValue(keys.keys()) {
                    let request = try #require(PodcastSubscriptions.feedRequest(url, sendsAccess: sendsAccess))
                    _ = try await RequestRetryPolicy.fetch(request, once: true, carriesServerHeaders: sendsAccess)
                }
            }
            await ServerHeadersWayTests.until { host.recorded.count > before }
            return try #require(host.recorded.dropFirst(before).first)
        }

        let own = try await read(sendsAccess: true)
        try #require(own.contains("authorization: basic"), "the control: the device's read carries its sign-in")
        try #require(ServerHeadersWayTests.carried(own) == 1, "the control: the device's read carries the server's header")
        try #require(own.contains("cookie: maer-probe="), "the control: the device's read carries the host's cookie")

        let link = try await read(sendsAccess: false)
        #expect(!link.contains("authorization:"), "a link's read carried the sign-in")
        #expect(ServerHeadersWayTests.carried(link) == 0, "a link's read carried the header the device keeps for the server")
        #expect(!link.contains("cookie:"), "a link's read carried the host's cookie")
    }

    @Test("a feed that means sign in says so, unless this device follows it; every other answer opens the show")
    func theReadsAnswer() {
        let show = PodcastShow(id: "feed:f", title: "T", author: nil, artworkURL: nil,
                               description: nil, feedURL: "https://f.example/feed.xml", episodes: [])
        #expect(SharedLinkOpener.feedRead(.show(show), follows: false) == .read)
        #expect(SharedLinkOpener.feedRead(.status(401), follows: false) == .signInNeeded)
        #expect(SharedLinkOpener.feedRead(.status(403), follows: false) == .signInNeeded)
        #expect(SharedLinkOpener.feedRead(.status(401), follows: true) == .failed,
                "a feed this device follows said it asks for a sign-in")
        #expect(SharedLinkOpener.feedRead(.status(404), follows: false) == .failed)
        #expect(SharedLinkOpener.feedRead(.status(500), follows: false) == .failed)
        #expect(SharedLinkOpener.feedRead(.failed(.timeout), follows: false) == .failed)
        #expect(SharedLinkOpener.feedRead(.accessUnknown, follows: false) == .failed)
    }

    @Test("the Basic header of a feed is built in one place for every way")
    func oneBasicHeader() {
        let present = PodcastFeedAuth.Access.present(user: "u", password: "p")
        #expect(PodcastFeedAuth.headers(for: present) == ["Authorization": "Basic dTpw"])
        #expect(PodcastFeedAuth.headers(for: .absent) == [:])
        #expect(PodcastFeedAuth.headers(for: .unknown) == nil)
    }

    @Test("the live open asks whether this device follows the feed, and the Basic header has one builder", .needsTheSources)
    func theWiring() throws {
        func code(_ path: String) throws -> String {
            SyncContractFenceTests.stripped(try String(contentsOf: SourceTree.root.appendingPathComponent(path), encoding: .utf8))
        }
        let opener = try code("Sources/ViewModels/SharedLinkOpener.swift")
        let live = try #require(ABSPodcastRefreshTests.body(of: "static func live(", in: opener))
        #expect(!live.contains("follows: false"), "the live open never asks whether this device follows the feed")
        let auth = try code("Sources/Networking/PodcastFeedAuth.swift")
        #expect(auth.components(separatedBy: "base64EncodedString()").count - 1 == 1, "the Basic header is built twice")
    }
}
#endif
