#if canImport(Testing)
import Testing
import CoreGraphics
@testable import ABSPlayer

/// D1/B1 — pure geometry of the full-player dismiss zones. The audited failure
/// cases are pinned here: chapter buttons dead on 375pt portrait, scrubber
/// covered by the top strip in iPhone landscape, iPad rails unchanged.
struct PlayerDismissZoneTests {

    @Test func sideZoneWidthMatchesLegacyFormula() {
        #expect(PlayerDismissZones.sideZoneWidth(containerWidth: 375) == 56)
        #expect(PlayerDismissZones.sideZoneWidth(containerWidth: 402) == 56)
        #expect(PlayerDismissZones.sideZoneWidth(containerWidth: 834) == 157)
        #expect(PlayerDismissZones.sideZoneWidth(containerWidth: 1032) == 256)
    }

    @Test func phonePortraitRailEndsAboveControls() {
        // iPhone 13 mini portrait: controls (chapter header…tertiary) start at
        // y=430 — the rail used to reach y=592 and swallowed the buttons.
        let fallback: CGFloat = 812 - 220
        let rail = CGRect(x: 0, y: 0, width: 56, height: fallback)
        let controls = CGRect(x: 16, y: 430, width: 343, height: 350)
        let h = PlayerDismissZones.zoneHeight(zoneRect: rail, controlsFrame: controls, fallback: fallback)
        #expect(h == 430 - PlayerDismissZones.controlsMargin)
        #expect(h < controls.minY)
    }

    @Test func iPadRailsDoNotIntersectContentColumn() {
        // iPad 11" portrait: the 157pt rail ends before the centered 500pt
        // column starts (x=167) — legacy full height must be kept.
        let fallback: CGFloat = 1194 - 220
        let rail = CGRect(x: 0, y: 0, width: 157, height: fallback)
        let controls = CGRect(x: 167, y: 300, width: 500, height: 500)
        let h = PlayerDismissZones.zoneHeight(zoneRect: rail, controlsFrame: controls, fallback: fallback)
        #expect(h == fallback)
    }

    @Test func landscapeTopStripEndsAboveScrubber() {
        // iPhone 17 Pro landscape: side-by-side layout puts the controls column
        // at y≈60 — the fixed topInset+130 strip used to cover the scrubber.
        let fallback: CGFloat = 24 + 130
        let strip = CGRect(x: 0, y: 0, width: 874, height: fallback)
        let controls = CGRect(x: 364, y: 60, width: 478, height: 300)
        let h = PlayerDismissZones.zoneHeight(zoneRect: strip, controlsFrame: controls, fallback: fallback)
        #expect(h == 60 - PlayerDismissZones.controlsMargin)
    }

    @Test func unknownControlsFrameKeepsFallback() {
        let strip = CGRect(x: 0, y: 0, width: 375, height: 180)
        #expect(PlayerDismissZones.zoneHeight(zoneRect: strip, controlsFrame: nil, fallback: 180) == 180)
        #expect(PlayerDismissZones.zoneHeight(zoneRect: strip, controlsFrame: .zero, fallback: 180) == 180)
    }

    @Test func topStripCoversWholeCoverAreaInPortrait() {
        // Portrait: the strip extends down to the controls edge (the cover has
        // no interactive elements) instead of the old fixed 130pt band.
        let controls = CGRect(x: 16, y: 430, width: 343, height: 350)
        let h = PlayerDismissZones.topZoneHeight(controlsFrame: controls, fallback: 24 + 130)
        #expect(h == 430 - PlayerDismissZones.controlsMargin)
    }

    @Test func topStripStaysAboveLandscapeScrubber() {
        let controls = CGRect(x: 364, y: 60, width: 478, height: 300)
        let h = PlayerDismissZones.topZoneHeight(controlsFrame: controls, fallback: 24 + 130)
        #expect(h == 60 - PlayerDismissZones.controlsMargin)
    }

    @Test func topStripFallsBackWhileControlsUnknown() {
        #expect(PlayerDismissZones.topZoneHeight(controlsFrame: nil, fallback: 154) == 154)
    }

    @Test func zoneHeightNeverNegative() {
        let strip = CGRect(x: 0, y: 0, width: 375, height: 180)
        let controls = CGRect(x: 0, y: 4, width: 375, height: 600)
        #expect(PlayerDismissZones.zoneHeight(zoneRect: strip, controlsFrame: controls, fallback: 180) == 0)
    }
}
#endif
