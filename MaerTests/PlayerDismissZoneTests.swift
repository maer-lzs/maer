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

    /// The pill's height starts at zero at every opening of the player,
    /// before it is measured: a gap of a few points below the controls must
    /// not take the pill then.
    @Test("eine noch nicht gemessene Pille nimmt keine kleine Luecke unter der Steuerung")
    func anUnmeasuredPillTakesNoSmallGap() {
        let upright = CGSize(width: 402, height: 874)
        // A few points below the controls, room above them.
        let controls = CGRect(x: 16, y: 400, width: 370, height: 418)
        let slot = PlayerDismissZones.noticeSlot(controlsFrame: controls, container: upright,
                                                 topInset: 62, bottomInset: 34, pillHeight: 0)
        let slotTop = slot?.minY
        #expect(slotTop == 62, "the unmeasured pill went into the gap below: \(String(describing: slot))")
        let height = slot?.height ?? 0
        #expect(height >= PlayerDismissZones.noticePillMinHeight, "the slot does not hold the pill: \(height)")
    }

    /// A title that cannot start says why in the full player exactly once
    /// in every position: the pill where it has room, else the line under
    /// the controls; scrolling from one to the other never shows both and
    /// never neither. The pill shows where the slot is (`FullPlayerOverlay`),
    /// the line asks the same answer.
    @Test("der Satz eines Titels, der nicht starten kann, steht im grossen Player in jeder Lage genau einmal: Pille mit Platz, Zeile ohne, beim Scrollen nie beides, nie keins")
    func aStoppingErrorStandsExactlyOnce() {
        let notice = PlaybackNotice.cannotPlay("Kein Titel")
        let upright = CGSize(width: 402, height: 874)
        func placed(_ controls: CGRect) -> (pill: Bool, line: String?) {
            let slot = PlayerDismissZones.noticeSlot(controlsFrame: controls, container: upright,
                                                     topInset: 62, bottomInset: 34, pillHeight: 38)
            return (slot != nil, NoticePlacement.lineUnderControls(shown: notice, held: notice, pillHasRoom: slot != nil))
        }
        let roomy = placed(CGRect(x: 16, y: 360, width: 370, height: 429))
        #expect(roomy.pill && roomy.line == nil, "with room: \(roomy)")
        let scrolled = placed(CGRect(x: 16, y: -300, width: 370, height: 1400))
        #expect(!scrolled.pill && scrolled.line == notice.label, "scrolled at AX3: \(scrolled)")
        var wrong: [String] = []
        for y in stride(from: 420.0, through: -400.0, by: -20.0) {
            let step = placed(CGRect(x: 16, y: y, width: 370, height: 1400))
            if step.pill == (step.line != nil) { wrong.append("y=\(y) pill=\(step.pill) line=\(step.line ?? "-")") }
        }
        #expect(wrong.isEmpty, "both or neither while scrolling: \(wrong)")
        // An info or a short error never takes the line: it is no stopping error.
        let info = NoticePlacement.lineUnderControls(shown: .serverAdopted, held: nil, pillHasRoom: false)
        let short = NoticePlacement.lineUnderControls(shown: .conflict, held: nil, pillHasRoom: false)
        #expect(info == nil && short == nil, "a notice that does not hold took the line: \(String(describing: info)) \(String(describing: short))")
        // Once the pill's time is up, or a short notice lies over it, the
        // held error takes the line, with room or without.
        for room in [true, false] {
            #expect(NoticePlacement.lineUnderControls(shown: nil, held: notice, pillHasRoom: room) == notice.label,
                    "the held error said nothing after its pill, room \(room)")
            #expect(NoticePlacement.lineUnderControls(shown: .conflict, held: notice, pillHasRoom: room) == notice.label,
                    "the held error said nothing under a short notice, room \(room)")
        }
        #expect(NoticePlacement.lineUnderControls(shown: nil, held: .waitingForNetwork, pillHasRoom: false) == nil,
                "the wait took the line")
    }

    /// The notice under the controls and the lasting failure can carry the
    /// same sentence (two failures map to one in `ErrorSentence.of`). It
    /// stands once; two different ones stand both, the notice first.
    @Test("traegt der Hinweis unter der Steuerung denselben Satz wie der bleibende Fehler, steht er einmal; zwei verschiedene stehen beide")
    func theSameSentenceStandsOnceUnderTheControls() {
        let notice = PlaybackNotice.cannotPlay("Kein Titel")
        let same = NoticePlacement.linesUnderControls(shown: notice, held: notice, pillHasRoom: false, error: notice.label)
        #expect(same == [notice.label], "the same sentence stood twice: \(same)")
        let other = NoticePlacement.linesUnderControls(shown: notice, held: notice, pillHasRoom: false, error: "Sync failed")
        #expect(other == [notice.label, "Sync failed"], "two sentences: \(other)")
        let onlyError = NoticePlacement.linesUnderControls(shown: notice, held: notice, pillHasRoom: true, error: notice.label)
        #expect(onlyError == [notice.label], "with room the pill says the notice, the error stays: \(onlyError)")
        #expect(NoticePlacement.linesUnderControls(shown: nil, held: nil, pillHasRoom: false, error: nil).isEmpty)
    }

    @Test("die Zeile unter der Steuerung fragt dieselbe Antwort wie die Pille", .needsTheSources)
    func theLineAsksTheSlotOfThePill() throws {
        func code(_ path: String) throws -> String {
            SyncContractFenceTests.stripped(try String(contentsOf: SourceTree.root.appendingPathComponent(path), encoding: .utf8))
        }
        let overlay = try code("Sources/Views/FullPlayerOverlay.swift")
        #expect(overlay.contains(".onChange(of: slot != nil, initial: true) { _, hasRoom in pillHasRoom = hasRoom }"),
                "the overlay does not hand the pill's room on")
        #expect(overlay.contains(".environment(\\.noticePillHasRoom, pillHasRoom)"), "the controls do not hear the pill's room")
        #expect(try code("Sources/Views/PlayerView.swift")
            .contains("ControlsNoticeLines(notices: coordinator.notices, error: viewModel.errorMessage)"),
                "the controls do not show the line")
    }
}
#endif
