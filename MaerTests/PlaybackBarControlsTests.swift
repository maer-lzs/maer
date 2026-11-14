// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
import CoreGraphics
@testable import Maer

/// The wide playback bar carries each medium's full controls, and the speed
/// and sleep menus exist once, for the full player and the bar alike.
struct PlaybackBarControlsTests {

    @Test("the wide bar per medium in groups and in today's order, play at the far right")
    func eachMediumGetsItsControls() {
        #expect(PlaybackBarControls.wide(isLive: false, isMusic: false)
                == [[.titleBack, .skipBack, .skipForward, .titleForward], [.speed, .sleepTimer, .airPlay], [.play]])
        #expect(PlaybackBarControls.wide(isLive: false, isMusic: true)
                == [[.titleBack, .titleForward], [.queue, .airPlay], [.play]])
        #expect(PlaybackBarControls.wide(isLive: true, isMusic: false) == [[.airPlay], [.play]])
        for groups in [PlaybackBarControls.wide(isLive: false, isMusic: false),
                       PlaybackBarControls.wide(isLive: false, isMusic: true),
                       PlaybackBarControls.wide(isLive: true, isMusic: false)] {
            #expect(groups.last == [.play], "play leaves the right edge or shares its group")
        }
    }

    @Test("above a fold the title ends before it, all buttons stand to the right of it")
    func overAFoldTheButtonsStandRightOfIt() {
        // Open Duo across: fold 455.5 to 495.5, a bar from 8 to 859.
        #expect(PlaybackBarControls.titleWidth(barMinX: 8, barWidth: 851, fold: 455.5...495.5, leadingPadding: 12)
                == 435.5)
        // No fold, or a fold outside the bar: no limit.
        #expect(PlaybackBarControls.titleWidth(barMinX: 8, barWidth: 851, fold: nil, leadingPadding: 12) == nil)
        #expect(PlaybackBarControls.titleWidth(barMinX: 500, barWidth: 300, fold: 455.5...495.5, leadingPadding: 12) == nil)
    }

    @Test("the bar sets the groups apart and puts the title before the fold", .needsTheSources)
    func theBarSetsTheGroupsApart() throws {
        let bar = SyncContractFenceTests.stripped(try String(
            contentsOf: SourceTree.root.appendingPathComponent("Sources/Views/MiniPlayerBar.swift"), encoding: .utf8))
        #expect(bar.contains("HStack(spacing: PlaybackBarControls.groupGap) {"))
        #expect(bar.contains("PlaybackBarControls.titleWidth(barMinX: barMinX"))
    }

    @Test("wide from a window of 600 pt")
    func wideFromSixHundred() {
        // Open Duo upright: a 669 window, the bar 649 wide.
        #expect(PlaybackBarControls.isWide(barWidth: 649))
        #expect(PlaybackBarControls.isWide(barWidth: 580))
        // Folded (466) and the half of a split (334): narrow.
        #expect(!PlaybackBarControls.isWide(barWidth: 446))
        #expect(!PlaybackBarControls.isWide(barWidth: 314))
    }

    @Test("the handle closes on tapping as on dragging, a drag over the image only from the threshold")
    func theHandleClosesOnATap() {
        // A tap on the handle: a pull that did not move.
        #expect(PlayerDismiss.closes(translation: .zero, predictedHeight: 0, threshold: 180, onHandle: true))
        #expect(PlayerDismiss.closes(translation: CGSize(width: 3, height: 4), predictedHeight: 4,
                                     threshold: 180, onHandle: true))
        // The same touch elsewhere does nothing; a small pull on the handle neither.
        #expect(!PlayerDismiss.closes(translation: .zero, predictedHeight: 0, threshold: 180, onHandle: false))
        #expect(!PlayerDismiss.closes(translation: CGSize(width: 0, height: 40), predictedHeight: 60,
                                      threshold: 180, onHandle: true))
        // A pull past the threshold or flung beyond twice it closes anywhere.
        #expect(PlayerDismiss.closes(translation: CGSize(width: 0, height: 200), predictedHeight: 220,
                                     threshold: 180, onHandle: false))
        #expect(PlayerDismiss.closes(translation: CGSize(width: 0, height: 90), predictedHeight: 400,
                                     threshold: 180, onHandle: false))
    }

    @Test("the drag stroke appears only without a sidebar, with it the sidebar's button closes", .needsTheSources)
    func theHandleStandsOnlyWithoutTheColumn() throws {
        let overlay = SyncContractFenceTests.stripped(
            try String(contentsOf: SourceTree.root.appendingPathComponent("Sources/Views/FullPlayerOverlay.swift"),
                       encoding: .utf8))
        #expect(overlay.contains("if columnPlacement == nil { grabHandle }"))
        #expect(overlay.components(separatedBy: "grabHandle").count - 1 == 2)
        #expect(overlay.contains(".accessibilityAction(.escape) { slideOutAndDismiss() }"))
        #expect(overlay.contains(".highPriorityGesture(dismissGesture(minimumDistance: 0, onHandle: true))"))
    }

    @Test("speed and sleep timer exist once: the choice item appears only in PlaybackMenus", .needsTheSources)
    func oneSpeedAndOneSleepMenu() throws {
        var found: [String] = []
        for file in ProjectFileIntegrityTests.sourceFiles() {
            let text = SyncContractFenceTests.stripped(try String(contentsOf: file, encoding: .utf8))
            // The menu's own forms: a show's start rate (its own picker) and
            // the view model's functions are no second menu.
            if text.contains("Picker(\"Speed\", selection: Binding(")
                || text.contains("viewModel.startSleepTimerUntilChapterEnd()") {
                found.append(file.lastPathComponent)
            }
        }
        #expect(found == ["PlaybackMenus.swift"], "a second speed or sleep menu: \(found)")
    }
}
#endif
