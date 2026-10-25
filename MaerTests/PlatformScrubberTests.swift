// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// The player's progress bar is one drawn form on every device: no
/// thumb, no chapter ticks, it grows while held, and its arithmetic
/// lives in `ScrubberMath`.
struct PlatformScrubberTests {
    @Test("der Balken ist eine Form ohne Griff und ohne Teilstriche, er waechst beim Halten", .needsTheSources)
    func theBarHasNoThumbAndNoTicks() throws {
        let read = { (path: String) in
            SyncContractFenceTests.stripped(
                try String(contentsOf: SourceTree.root.appendingPathComponent(path), encoding: .utf8))
        }
        let bar = try read("Sources/Views/PlatformScrubber.swift")
        #expect(!bar.contains("Circle()"), "the bar carries a thumb again")
        #expect(!bar.contains("Slider("), "the system slider is back")
        #expect(bar.contains("let height = dragging ? Self.heldHeight : Self.restHeight"))
        #expect(PlatformScrubber.heldHeight > PlatformScrubber.restHeight)
        #expect(bar.contains(".accessibilityAdjustableAction"))
        let player = try read("Sources/Views/PlayerView.swift")
        #expect(!player.contains("chapter.start / viewModel.duration"), "chapter ticks are back on the bar")
    }

    // The case that used to stand here asked `PlatformIdiom.isAppOnMac` and
    // expected false. That measures the MACHINE the suite happens to run on,
    // not anything this project builds: it would answer the same over any
    // implementation, and it would go red on a correct build run somewhere
    // else. Removed rather than fixed, because there is nothing to fix.

    // MARK: - The arithmetic, at its edges

    /// The three calculations were private members of the view, so nothing
    /// could reach them. Each one clamps and one of them divides, which is
    /// the half of this control that can actually be wrong.
    @Test("die Rechnung haelt ihre Kanten")
    func theArithmeticHoldsItsEdges() {
        let track = 0.0...120.0
        #expect(ScrubberMath.fraction(of: 60, in: track) == 0.5)
        #expect(ScrubberMath.fraction(of: -10, in: track) == 0, "vor dem Anfang ist der Anfang")
        #expect(ScrubberMath.fraction(of: 999, in: track) == 1, "hinter dem Ende ist das Ende")
    }

    /// A track of no length. It arises before a duration is known, and the
    /// answer must be a number: a division here would put a NaN into a frame
    /// width and take the layout with it.
    ///
    /// **The value sits AT the bound, and that is the whole case.** The first
    /// version of this witness asked for 5 on a track of 7 to 7, which
    /// divides to minus infinity, and the clamp below catches that and
    /// answers 0. So the case passed with the guard removed, and it was the
    /// red probe that said so. Only a value ON the bound divides zero by
    /// zero, and NaN walks straight through `min` and `max` in Swift,
    /// because every comparison with it is false.
    @Test("eine Spur ohne Laenge teilt nicht")
    func anEmptyTrackDoesNotDivide() {
        #expect(ScrubberMath.fraction(of: 7, in: 7.0...7.0).isNaN == false,
                "0 durch 0 ist NaN, und NaN geht durch jede Klemmung hindurch")
        #expect(ScrubberMath.fraction(of: 7, in: 7.0...7.0) == 0)
        #expect(ScrubberMath.fraction(of: 5, in: 7.0...7.0) == 0, "auch davor")
    }

    /// The guard that used to live at the CALL SITE, as the caller's
    /// `max(geo.size.width, 1)`. A safeguard kept by whoever calls is a claim
    /// about every future caller; this case is what makes it a property of
    /// the calculation instead.
    @Test("eine Breite von null wird hier abgefangen, nicht beim Rufer")
    func zeroWidthIsCaughtHereAndNotByTheCaller() {
        let track = 10.0...70.0
        #expect(ScrubberMath.value(atX: 5, width: 0, in: track) == 10)
        #expect(ScrubberMath.value(atX: 5, width: 0, in: track).isNaN == false)
        #expect(ScrubberMath.value(atX: 50, width: 100, in: track) == 40)
        #expect(ScrubberMath.value(atX: -20, width: 100, in: track) == 10, "links vom Anfang")
        #expect(ScrubberMath.value(atX: 500, width: 100, in: track) == 70, "rechts vom Ende")
    }

    /// The adjustable action is how somebody moves this control without
    /// seeing it, so its step has to arrive somewhere and to stop at both
    /// ends.
    @Test("ein Schritt kommt an und laeuft an beiden Enden nicht hinaus")
    func aStepArrivesAndStopsAtBothEnds() {
        let track = 0.0...200.0
        #expect(ScrubberMath.step(in: track) == 10)
        #expect(ScrubberMath.stepped(from: 100, in: track, increasing: true) == 110)
        #expect(ScrubberMath.stepped(from: 100, in: track, increasing: false) == 90)
        #expect(ScrubberMath.stepped(from: 195, in: track, increasing: true) == 200)
        #expect(ScrubberMath.stepped(from: 5, in: track, increasing: false) == 0)
    }

    /// On a short track a twentieth is a fraction of a second, and a control
    /// that moves by that feels dead to somebody stepping through it.
    @Test("auf einer kurzen Spur ist ein Schritt mindestens eine Sekunde")
    func onAShortTrackAStepIsAtLeastASecond() {
        #expect(ScrubberMath.step(in: 0.0...10.0) == 1)
        #expect(ScrubberMath.stepped(from: 0, in: 0.0...10.0, increasing: true) == 1)
    }
}
#endif
