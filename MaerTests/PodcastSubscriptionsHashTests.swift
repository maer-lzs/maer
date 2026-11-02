// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
@testable import Maer

/// The feed hash is not FNV-1a (its start value lacks a digit), and it must
/// stay exactly as it is: show ids `feed:<key>`, episode ids `rss:<key>:<guid>`
/// and the positions stored under them are built from it. Two fixed values,
/// so that "fixing" the start value fails here instead of orphaning every
/// stored id.
struct PodcastSubscriptionsHashTests {
    @Test("Der Feed-Hash bleibt, wie er ist, auch wenn er nicht FNV-1a ist")
    func theFeedHashNeverChanges() {
        #expect(PodcastIdentity.stableHash("") == "14650fb0739d0383")
        #expect(PodcastIdentity.stableHash("example.com/feed") == "2df29e1f29180479")
        #expect(PodcastIdentity.stableHash("") != "cbf29ce484222325", "the real FNV-1a of the empty string")
    }
}
#endif
