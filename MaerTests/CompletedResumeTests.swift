// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// A finished title has nothing left to resume (its saved position is the
/// end), so a deliberate play restarts it from the beginning. But a silent
/// session restore must never reset it.
struct CompletedResumeTests {
    @Test("deliberate play of a finished title restarts")
    func finishedAutoplayRestarts() {
        #expect(PlayerCoordinator.resolvesToRestart(explicitRestart: false, autoplay: true, isFinished: true))
    }

    @Test("silent restore of a finished title does NOT restart")
    func finishedSilentRestoreKeeps() {
        #expect(!PlayerCoordinator.resolvesToRestart(explicitRestart: false, autoplay: false, isFinished: true))
    }

    @Test("an unfinished title resumes (no restart) whether or not autoplay")
    func unfinishedResumes() {
        #expect(!PlayerCoordinator.resolvesToRestart(explicitRestart: false, autoplay: true, isFinished: false))
        #expect(!PlayerCoordinator.resolvesToRestart(explicitRestart: false, autoplay: false, isFinished: false))
    }

    @Test("an explicit restart always restarts")
    func explicitRestartWins() {
        #expect(PlayerCoordinator.resolvesToRestart(explicitRestart: true, autoplay: false, isFinished: false))
    }

    // MARK: - A fixed-minutes sleep timer carries across item changes

    @Test("a running fixed-minutes timer carries to the next title")
    func fixedTimerCarries() {
        #expect(PlayerCoordinator.carriedSleepRemaining(remaining: 600, untilChapterEnd: false, untilTrackEnd: false) == 600)
    }

    @Test("no timer / zero does not carry")
    func noTimerNoCarry() {
        #expect(PlayerCoordinator.carriedSleepRemaining(remaining: nil, untilChapterEnd: false, untilTrackEnd: false) == nil)
        // A sleep bound to the chapter or track ends with the title, fixed minutes do not.
        #expect(PlayerCoordinator.sleepEndsWithTitle(untilChapterEnd: true, untilTrackEnd: false))
        #expect(PlayerCoordinator.sleepEndsWithTitle(untilChapterEnd: false, untilTrackEnd: true))
        #expect(!PlayerCoordinator.sleepEndsWithTitle(untilChapterEnd: false, untilTrackEnd: false))
        #expect(PlayerCoordinator.carriedSleepRemaining(remaining: 0, untilChapterEnd: false, untilTrackEnd: false) == nil)
    }

    @Test("a position-based timer (chapter/track end) does NOT carry — it is bound to the item")
    func positionTimerDoesNotCarry() {
        #expect(PlayerCoordinator.carriedSleepRemaining(remaining: 120, untilChapterEnd: true, untilTrackEnd: false) == nil)
        #expect(PlayerCoordinator.carriedSleepRemaining(remaining: 120, untilChapterEnd: false, untilTrackEnd: true) == nil)
    }

    /// The advance at a title's end asks the sleep before it opens the next
    /// title: a sleep until the end of the chapter or track ends there.
    @Test("the advance at the end of a title asks the sleep until chapter end before it opens the next", .needsTheSources)
    func theAdvanceAsksTheSleepFirst() throws {
        let coordinator = try FetchAnswerTests.squeezedSource("Sources/ViewModels/PlayerCoordinator.swift")
        let asked = try #require(coordinator.range(of: "if let model = viewModel, Self.sleepEndsWithTitle(untilChapterEnd: model.sleepUntilChapterEnd,"),
                                 "the advance does not ask the sleep")
        let next = try #require(coordinator.range(of: "guard let next = resolveAdvance(after: finishedItemId) else { return }"))
        #expect(asked.lowerBound < next.lowerBound, "the sleep is asked after the next title is chosen")
    }
}
#endif
