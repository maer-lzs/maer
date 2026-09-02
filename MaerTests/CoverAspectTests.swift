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
    @Test("ein quadratisches Cover bleibt beim Fuellen, wie bisher")
    func squareKeepsFilling() {
        #expect(!CoverAspect.needsFitting(width: 1400, height: 1400))
        #expect(CoverAspect.distanceFromSquare(width: 1400, height: 1400) == 0)
    }

    /// Die Rot-Probe des Auftrags: 99 % der Kacheln sehen schon gut aus
    /// und duerfen sich NICHT aendern. Ein leicht schief gescanntes Cover
    /// liegt weit unter der Schwelle.
    @Test("leicht abweichende Cover bleiben unveraendert")
    func nearlySquareKeepsFilling() {
        #expect(!CoverAspect.needsFitting(width: 1000, height: 1050))
        #expect(!CoverAspect.needsFitting(width: 1200, height: 1000))
        // Genau auf der Schwelle wird noch gefuellt, erst darueber gefittet.
        #expect(!CoverAspect.needsFitting(width: 1200, height: 1000, tolerance: 0.2))
    }

    @Test("ein 16:9-Bild wird eingepasst statt beschnitten")
    func wideNeedsFitting() {
        #expect(CoverAspect.needsFitting(width: 1280, height: 720))
        let distance = CoverAspect.distanceFromSquare(width: 1280, height: 720)
        #expect(abs(distance - 0.7777) < 0.001)
    }

    /// Die Regel kennt keine Vorliebe fuer Querformat: dieselbe
    /// Abweichung hochkant wird genauso behandelt.
    @Test("hochkant wird genauso eingepasst wie quer")
    func tallNeedsFittingToo() {
        #expect(CoverAspect.needsFitting(width: 720, height: 1280))
        #expect(CoverAspect.distanceFromSquare(width: 720, height: 1280)
                == CoverAspect.distanceFromSquare(width: 1280, height: 720))
    }

    /// Ein Bild ohne gemeldete Masse darf die Kachel NICHT umstellen.
    /// Die sichere Richtung ist das heutige Verhalten; ein falsches
    /// „einpassen" wuerde ein Cover aendern, das schon richtig war.
    @Test("ohne Masse bleibt es beim heutigen Verhalten")
    func degenerateSizeChangesNothing() {
        #expect(!CoverAspect.needsFitting(width: 0, height: 0))
        #expect(!CoverAspect.needsFitting(width: 0, height: 720))
        #expect(!CoverAspect.needsFitting(width: -10, height: 10))
    }
}
#endif
