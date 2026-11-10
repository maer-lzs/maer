// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Foundation
import Testing
@testable import Maer

/// No feed address from outside ends the app: a pair of the query without
/// a name is no part of the identity.
struct FeedQueryPairTests {

    @Test("ein Abfrageteil mit einem Paar ohne Namen bricht nicht ab und gehoert nicht zur Identitaet",
          arguments: [("https://a.example/f?=", "a.example/f"), ("https://a.example/f?a=1&=", "a.example/f"),
                      ("https://a.example/f?&", "a.example/f"), ("https://a.example/f?=x", "a.example/f"),
                      ("https://a.example/f?=&token=abc&==", "a.example/f?token=abc"),
                      ("https://a.example/f?token", "a.example/f?token"),
                      ("https://a.example/f?", "a.example/f")])
    func aPairWithoutANameDoesNotEndTheApp(address: String, normalized: String) {
        #expect(PodcastIdentity.normalizeFeedURL(address) == normalized)
        #expect(!PodcastIdentity.feedKey(address).isEmpty)
        #expect(!PodcastIdentity.collapseKey(address).isEmpty)
        #expect(PodcastIdentity.maskedFeedURL(address).hasPrefix("https://a.example/f?"))
        _ = PodcastFeedAddress.isTokenFeedURL(address)
    }
}
#endif
