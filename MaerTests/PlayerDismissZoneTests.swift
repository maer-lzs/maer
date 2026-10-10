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

    /// The four layouts measured on the app image (iPhone 17, a stopping
    /// notice standing): the slot lies below, beside or above the controls,
    /// never over them, and the pill fits in it. Where the controls fill the
    /// visible player there is no slot.
    @Test("die Pille im grossen Player steht nie ueber der Steuerung: unter, neben oder ueber ihr, sonst gar nicht")
    func theNoticeSlotNeverCoversTheControls() throws {
        let pill: CGFloat = 38
        let upright = CGSize(width: 402, height: 874)
        let sideways = CGSize(width: 874, height: 402)
        let cases: [(String, CGRect, CGSize, CGFloat, CGFloat, CGFloat?)] = [
            // name, controls, container, top inset, bottom inset, expected slot top (nil: none)
            ("hochkant", CGRect(x: 16, y: 360, width: 370, height: 429), upright, 62, 34, 797),
            ("hochkant AX3", CGRect(x: 16, y: 420, width: 370, height: 900), upright, 62, 34, 62),
            ("quer", CGRect(x: 370, y: 20, width: 472, height: 383), sideways, 0, 21, 0),
            ("quer AX3", CGRect(x: 370, y: 20, width: 472, height: 700), sideways, 0, 21, 0),
            ("gescrollt AX3", CGRect(x: 16, y: -300, width: 370, height: 1400), upright, 62, 34, nil),
        ]
        for (name, controls, container, top, bottom, expectedTop) in cases {
            let slot = PlayerDismissZones.noticeSlot(controlsFrame: controls, container: container,
                                                     topInset: top, bottomInset: bottom, pillHeight: pill)
            let slotTop = slot?.minY
            #expect(slotTop == expectedTop, "\(name): slot \(String(describing: slot))")
            guard let slot else { continue }
            #expect(!slot.intersects(controls), "\(name): the slot lies over the controls \(slot)")
            #expect(slot.height >= pill, "\(name): the pill does not fit \(slot)")
            #expect(slot.maxY <= container.height - bottom, "\(name): the slot runs into the bottom inset \(slot)")
        }
        #expect(PlayerDismissZones.noticeSlot(controlsFrame: nil, container: upright,
                                              topInset: 62, bottomInset: 34, pillHeight: pill) == nil,
                "a slot while the controls frame is unknown")
    }
}
#endif
