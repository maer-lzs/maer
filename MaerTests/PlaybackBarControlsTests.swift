// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// The wide playback bar carries each medium's full controls, and the speed
/// and sleep menus exist once, for the full player and the bar alike.
struct PlaybackBarControlsTests {

    @Test("die breite Leiste je Medium: Buch und Folge, Musik, Radio")
    func eachMediumGetsItsControls() {
        #expect(PlaybackBarControls.wide(isLive: false, isMusic: false)
                == [.titleBack, .skipBack, .skipForward, .titleForward, .speed, .sleepTimer])
        #expect(PlaybackBarControls.wide(isLive: false, isMusic: true) == [.titleBack, .titleForward, .queue])
        #expect(PlaybackBarControls.wide(isLive: true, isMusic: false).isEmpty)
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
