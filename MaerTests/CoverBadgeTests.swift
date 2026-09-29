// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import CoreGraphics
@testable import Maer

/// The shared badge size is 22% of the tile width, clamped [18, 44].
struct CoverBadgeTests {
    @Test("badge size is 22% of the tile, clamped to [18, 44]")
    func size() {
        #expect(CoverBadge.size(tileWidth: 160) == 160 * 0.22)   // 35.2, in range
        #expect(CoverBadge.size(tileWidth: 60) == 18)            // 13.2 → clamped up
        #expect(CoverBadge.size(tileWidth: 400) == 44)           // 88 → clamped down
        #expect(CoverBadge.size(tileWidth: 200) == 44)           // exactly the cap
    }

    /// The detail pages' status/download controls are the family's size
    /// reference. The default cap IS that reference, so no cover badge grows
    /// past the detail control; the 22 % formula only scales small tiles down.
    @Test("the detail control is the default cap of the badge family")
    func detailControlIsReference() {
        #expect(CoverBadge.detailControl == 44)
        #expect(CoverBadge.size(tileWidth: 1000) == CoverBadge.detailControl)
        #expect(CoverBadge.size(tileWidth: 1000, cap: CoverBadge.detailControl)
                == CoverBadge.size(tileWidth: 1000))
    }
}
#endif
