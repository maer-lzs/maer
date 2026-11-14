// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Foundation
import Testing
@testable import Maer

/// Test of the PodcastIndex signature. SHA1(Key+Secret+Date). A wrong
/// hash would show up only as a 401 at the server.
struct PodcastDirectoryTests {

    @Test("SHA1 auth header against a known value")
    func authHeaderMatchesKnownSHA1() {
        // SHA1("abc") = a9993e364706816aba3e25717850c26c9cd0d89d
        let header = PodcastIndexDirectory.authHeader(key: "a", secret: "b", date: "c")
        #expect(header == "a9993e364706816aba3e25717850c26c9cd0d89d")
    }
}
#endif
