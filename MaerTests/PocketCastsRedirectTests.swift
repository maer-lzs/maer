// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// The sign-in to Pocket Casts follows no redirect, so the password never
/// travels to another place; the reads follow one only to the three hosts
/// of Pocket Casts over https, so the token stays with them.
struct PocketCastsRedirectTests {
    @Test("the reads follow a redirect only to a host of Pocket Casts over https")
    func rule() throws {
        for host in ["api.pocketcasts.com", "refresh.pocketcasts.com", "cache.pocketcasts.com"] {
            #expect(PocketCastsClient.followsTo(try #require(URL(string: "https://\(host)/x"))))
            #expect(!PocketCastsClient.followsTo(try #require(URL(string: "http://\(host)/x"))), "plain http")
        }
        #expect(!PocketCastsClient.followsTo(try #require(URL(string: "https://elsewhere.example/user/login"))))
        #expect(!PocketCastsClient.followsTo(try #require(URL(string: "https://api.pocketcasts.com.elsewhere.example/x"))))
    }

    @Test("Fence: the sign-in follows no redirect, every other way only by the rule", .needsTheSources)
    func ways() throws {
        let client = SyncContractFenceTests.stripped(try String(contentsOf: SourceTree.root.appendingPathComponent("Sources/Networking/PocketCastsClient.swift"), encoding: .utf8))
        let signIn = try #require(client.range(of: "private static func signIn("))
        #expect(client[signIn.upperBound...].prefix(600).contains("redirects: .followingNone()"))
        let send = try #require(client.range(of: "private static func send("))
        #expect(client[send.upperBound...].prefix(300).contains("RequestRetryPolicy.fetch(request, redirects: redirects)"))
        #expect(client.contains("RedirectGuard(allows: { followsTo($0) })"))
    }
}
#endif
