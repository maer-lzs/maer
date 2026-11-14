// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// The rule that decides fill against fit. The load-bearing case is the
/// one where NOTHING changes: almost every cover in the app is square or
/// nearly so, and those must keep behaving exactly as before.
struct CoverAspectTests {
    @Test("a square cover stays filled, as before")
    func squareKeepsFilling() {
        #expect(!CoverAspect.needsFitting(width: 1400, height: 1400))
        #expect(CoverAspect.distanceFromSquare(width: 1400, height: 1400) == 0)
    }

    /// The red probe of the order: 99 % of the tiles already look good
    /// and must NOT change. A slightly skewed scanned cover
    /// is far below the threshold.
    @Test("slightly deviating covers stay unchanged")
    func nearlySquareKeepsFilling() {
        #expect(!CoverAspect.needsFitting(width: 1000, height: 1050))
        #expect(!CoverAspect.needsFitting(width: 1200, height: 1000))
        // Exactly at the threshold it is still filled, only above it fitted.
        #expect(!CoverAspect.needsFitting(width: 1200, height: 1000, tolerance: 0.2))
    }

    @Test("a 16:9 picture is fitted instead of cropped")
    func wideNeedsFitting() {
        #expect(CoverAspect.needsFitting(width: 1280, height: 720))
        let distance = CoverAspect.distanceFromSquare(width: 1280, height: 720)
        #expect(abs(distance - 0.7777) < 0.001)
    }

    /// The rule has no preference for landscape: the same
    /// deviation in portrait is treated the same way.
    @Test("portrait is fitted the same as landscape")
    func tallNeedsFittingToo() {
        #expect(CoverAspect.needsFitting(width: 720, height: 1280))
        #expect(CoverAspect.distanceFromSquare(width: 720, height: 1280)
                == CoverAspect.distanceFromSquare(width: 1280, height: 720))
    }

    /// A picture without reported dimensions must NOT switch the tile.
    /// The safe direction is today's behaviour; a wrong
    /// „einpassen" would change a cover that was already right.
    @Test("without dimensions it stays at today's behaviour")
    func degenerateSizeChangesNothing() {
        #expect(!CoverAspect.needsFitting(width: 0, height: 0))
        #expect(!CoverAspect.needsFitting(width: 0, height: 720))
        #expect(!CoverAspect.needsFitting(width: -10, height: 10))
    }
}
#endif
