// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import CoreGraphics
import Foundation
@testable import Maer

/// Pure geometry of the full-player dismiss zones. The audited failure
/// cases are pinned here: chapter buttons dead on 375pt portrait, scrubber
/// covered by the top strip in iPhone landscape.
struct PlayerDismissZoneTests {
    /// The side strips are fixed and narrow, and the scrubber is inset past
    /// them, so no control lies under a strip on any width.
    @Test func theScrubberLiesPastTheSideStrips() {
        #expect(PlayerDismissZones.sideStripWidth == 20)
        #expect(PlayerDismissZones.scrubberInset > PlayerDismissZones.sideStripWidth)
    }

    /// The live row stands where the scrubber stands, with a menu at its
    /// edge: both take the one inset, so neither lies under a strip.
    @Test("die Live-Zeile nimmt den Rand des Scrubbers", .needsTheSources)
    func theLiveRowTakesTheScrubbersInset() throws {
        let code = SyncContractFenceTests.stripped(try String(
            contentsOf: SourceTree.root.appendingPathComponent("Sources/Views/PlayerView.swift"), encoding: .utf8))
        let live = try #require(code.range(of: "private var liveRow: some View {"), "the precondition: the live row was read")
        let body = code[live.upperBound...].prefix(600)
        #expect(body.contains(".padding(.horizontal, PlayerDismissZones.scrubberInset)"),
                "the live row has its own number for the inset")
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

    @Test func bottomZoneCoversSpaceBelowControls() {
        let controls = CGRect(x: 16, y: 300, width: 343, height: 400)  // ends at 700
        let zone = PlayerDismissZones.bottomZone(controlsFrame: controls, containerHeight: 900)
        #expect(zone.top == 700 + PlayerDismissZones.controlsMargin)
        #expect(zone.height == 900 - (700 + PlayerDismissZones.controlsMargin))
    }

    @Test func bottomZoneEmptyWhileControlsUnknown() {
        let zone = PlayerDismissZones.bottomZone(controlsFrame: nil, containerHeight: 900)
        #expect(zone.height == 0)
    }

    @Test func bottomZoneNeverNegativeWhenControlsFillScreen() {
        let controls = CGRect(x: 0, y: 0, width: 375, height: 900)
        let zone = PlayerDismissZones.bottomZone(controlsFrame: controls, containerHeight: 900)
        #expect(zone.height == 0)
    }
}
#endif
