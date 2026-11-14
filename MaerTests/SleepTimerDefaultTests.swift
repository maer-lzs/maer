// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Testing
import Foundation
@testable import Maer

/// The sleep timer remembers the duration it was last started with. Whoever
/// sets the same thirty minutes every evening finds it at the top, instead of
/// hitting the same row every time.
struct SleepTimerDefaultTests {

    @Test("nothing remembered is no offer, and a zero is never remembered")
    func nothingRememberedIsNoOffer() {
        let key = AppStorageKeys.sleepTimerLastMinutes
        let vorher = UserDefaults.standard.object(forKey: key)
        defer {
            if let vorher { UserDefaults.standard.set(vorher, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
        }
        UserDefaults.standard.removeObject(forKey: key)
        #expect(AppStorageKeys.sleepTimerRemembered == nil,
                "ein leerer Speicher bietet eine Dauer an, die es nie gab")

        // A zero is no duration. Without this clause the menu would offer
        // „Wieder: 0 min" as soon as anything writes a zero into it.
        AppStorageKeys.rememberSleepTimer(minutes: 0)
        #expect(AppStorageKeys.sleepTimerRemembered == nil,
                "eine Null ist als Vorgabe gemerkt worden")

        AppStorageKeys.rememberSleepTimer(minutes: 30)
        #expect(AppStorageKeys.sleepTimerRemembered == 30)
        // Red probe at the instrument: the memory spot also takes a DIFFERENT
        // duration. A store that always returns the same number would report
        // the line above just as green.
        AppStorageKeys.rememberSleepTimer(minutes: 45)
        #expect(AppStorageKeys.sleepTimerRemembered == 45)
    }

    /// It is remembered at the ONE place where a clock duration starts.
    /// If it lay at the menu, the driving mode or a later caller would
    /// remember nothing, and the default would differ by path.
    @Test("it is remembered on start, not in the menu", .needsTheSources)
    func theStartRemembersIt() throws {
        let quelle = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("Sources/ViewModels/PlayerViewModel+SleepTimer.swift"),
            encoding: .utf8)
        let rumpf = try #require(functionBody(of: "func startSleepTimer(minutes: Double) {",
                                             in: quelle))
        #expect(rumpf.contains("rememberSleepTimer"),
                "die Dauer wird beim Starten nicht mehr gemerkt")

        // And the two LIMIT timers remember nothing:
        // „bis zum Ende des Kapitels" is no duration and means something
        // different for every piece.
        for grenze in ["func startSleepTimerUntilChapterEnd() {",
                       "func startSleepTimerUntilTrackEnd() {"] {
            let anderer = try #require(functionBody(of: grenze, in: quelle))
            #expect(!anderer.contains("rememberSleepTimer"),
                    "\(grenze) merkt sich eine Dauer, die es nicht ist")
        }
    }
}
