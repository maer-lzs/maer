// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Foundation
import Testing
@testable import Maer

/// The stable ids of the podcast stock live in one pure type. A copy back
/// in the subscriptions would put each rule in two places again, and a
/// forwarding name is a second name for the same rule.
struct PodcastIdentityFenceTests {
    static let moved = ["feedKey", "addressLine", "stableHash", "showTitle", "feedHost", "maskedFeedURL",
                        "normalizeFeedURL", "collapseKey", "migrate", "collapseInto", "originalGuid",
                        "twinEpisodeId", "merge", "carryStoreFacts"]

    /// Whether `text` declares `name` as a static member of any kind: a
    /// function, or a forwarding constant or property.
    static func declares(_ name: String, in text: String) -> Bool {
        text.range(of: #"static (func|let|var) \#(name)\b"#, options: .regularExpression) != nil
    }

    @Test("the stable identifiers of the subscriptions appear only in PodcastIdentity, without forwarding", .needsTheSources)
    func theStableIdsLiveInOnePlace() throws {
        let subscriptions = try FetchAnswerTests.squeezedSource("Sources/Providers/PodcastSubscriptions.swift")
        for name in Self.moved {
            #expect(!Self.declares(name, in: subscriptions), "\(name) is declared in the subscriptions again")
        }
        let identity = try FetchAnswerTests.squeezedSource("Sources/Models/PodcastIdentity.swift")
        for name in Self.moved {
            #expect(identity.contains("static func \(name)("), "\(name) left the pure type")
        }
        // One name for each set and rule of the feed address, in its own type.
        for name in ["isTokenFeedURL", "secretQueryParams"] {
            var declaring: [String] = []
            for (file, text) in ProjectFileIntegrityTests.sourceTexts()
            where Self.declares(name, in: FetchAnswerTests.squeezed(text)) {
                declaring.append(file)
            }
            #expect(declaring == ["PodcastFeedAddress.swift"], "a second name for \(name): \(declaring)")
        }
    }

    /// The fence reads every kind of declaration, not only a function.
    @Test("the fence recognizes a forwarding as func, let and var")
    func theFenceSeesEveryKind() {
        #expect(Self.declares("feedKey", in: "nonisolated static func feedKey(_ url: String) -> String"))
        #expect(Self.declares("feedKey", in: "static let feedKey = PodcastIdentity.feedKey"))
        #expect(Self.declares("feedKey", in: "static var feedKey: (String) -> String { PodcastIdentity.feedKey }"))
        #expect(!Self.declares("feedKey", in: "static func feedKeys(_ urls: [String]) -> [String]"))
        #expect(!Self.declares("feedKey", in: "let key = PodcastIdentity.feedKey(url)"))
    }
}
#endif
