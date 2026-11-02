// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
@testable import Maer

/// The stable ids of the podcast stock live in one pure type. A copy back
/// in the subscriptions would put each rule in two places again, and a
/// forwarding name is a second name for the same rule.
struct PodcastIdentityFenceTests {
    static let moved = ["feedKey", "addressLine", "stableHash", "showTitle", "feedHost", "maskedFeedURL",
                        "normalizeFeedURL", "collapseKey", "migrate", "collapseInto", "originalGuid",
                        "twinEpisodeId", "merge", "carryStoreFacts"]

    @Test("die stabilen Kennungen der Abos stehen nur in PodcastIdentity, ohne Weiterleitung", .needsTheSources)
    func theStableIdsLiveInOnePlace() throws {
        let subscriptions = try FetchAnswerTests.squeezedSource("Sources/Providers/PodcastSubscriptions.swift")
        for name in Self.moved {
            #expect(!subscriptions.contains("static func \(name)("), "\(name) is declared in the subscriptions again")
        }
        #expect(!subscriptions.contains("static let secretQueryParams"), "the secret parameters are declared twice")
        let identity = try FetchAnswerTests.squeezedSource("Sources/Models/PodcastIdentity.swift")
        for name in Self.moved {
            #expect(identity.contains("static func \(name)("), "\(name) left the pure type")
        }
        var tokenRules: [String] = []
        for (name, text) in ProjectFileIntegrityTests.sourceTexts() where text.contains("func isTokenFeedURL(") {
            tokenRules.append(name)
        }
        #expect(tokenRules == ["PodcastFeedAddress.swift"], "a second name for the token rule: \(tokenRules)")
    }
}
#endif
