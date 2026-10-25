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

    @Test("die breite Leiste je Medium in Gruppen und in der Reihenfolge von heute, Play ganz rechts")
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

    @Test("ueber einem Falz endet der Titel vor ihm, alle Knoepfe stehen rechts davon")
    func overAFoldTheButtonsStandRightOfIt() {
        // Open Duo across: fold 455.5 to 495.5, a bar from 8 to 859.
        #expect(PlaybackBarControls.titleWidth(barMinX: 8, barWidth: 851, fold: 455.5...495.5, leadingPadding: 12)
                == 435.5)
        // No fold, or a fold outside the bar: no limit.
        #expect(PlaybackBarControls.titleWidth(barMinX: 8, barWidth: 851, fold: nil, leadingPadding: 12) == nil)
        #expect(PlaybackBarControls.titleWidth(barMinX: 500, barWidth: 300, fold: 455.5...495.5, leadingPadding: 12) == nil)
    }

    @Test("die Leiste setzt die Gruppen ab und legt den Titel vor den Falz", .needsTheSources)
    func theBarSetsTheGroupsApart() throws {
        let bar = SyncContractFenceTests.stripped(try String(
            contentsOf: SourceTree.root.appendingPathComponent("Sources/Views/MiniPlayerBar.swift"), encoding: .utf8))
        #expect(bar.contains("HStack(spacing: PlaybackBarControls.groupGap) {"))
        #expect(bar.contains("PlaybackBarControls.titleWidth(barMinX: barMinX"))
    }

    @Test("breit ab einem Fenster von 600 pt")
    func wideFromSixHundred() {
        // Open Duo upright: a 669 window, the bar 649 wide.
        #expect(PlaybackBarControls.isWide(barWidth: 649))
        #expect(PlaybackBarControls.isWide(barWidth: 580))
        // Folded (466) and the half of a split (334): narrow.
        #expect(!PlaybackBarControls.isWide(barWidth: 446))
        #expect(!PlaybackBarControls.isWide(barWidth: 314))
    }

    @Test("der Griff schliesst auf Tippen wie auf Ziehen, ein Ziehen ueber dem Bild nur ab der Schwelle")
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

    @Test("Tempo und Schlaftimer gibt es einmal: der Wahlpunkt steht nur in PlaybackMenus", .needsTheSources)
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
