// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
@testable import Maer

/// gpodder ↔ ABS-podcasts are mutually exclusive (one external podcast server at
/// a time). RSS is a separate flag, not modeled here → inherently unaffected.
struct PodcastServerExclusivityTests {
    typealias E = PodcastServerExclusivity

    @Test("enabling one server clears the other; disabling leaves the other alone")
    func exclusivity() {
        // gpodder turned ON while ABS was ON → ABS off.
        #expect(E.resolved(gpodder: true, abs: true, changed: .gpodder) == (true, false))
        // gpodder turned OFF → ABS untouched.
        #expect(E.resolved(gpodder: false, abs: true, changed: .gpodder) == (false, true))
        // ABS turned ON while gpodder was ON → gpodder off.
        #expect(E.resolved(gpodder: true, abs: true, changed: .abs) == (false, true))
        // ABS turned OFF → gpodder untouched.
        #expect(E.resolved(gpodder: true, abs: false, changed: .abs) == (true, false))
        // Both off stays off.
        #expect(E.resolved(gpodder: false, abs: false, changed: .gpodder) == (false, false))
    }
}
#endif
