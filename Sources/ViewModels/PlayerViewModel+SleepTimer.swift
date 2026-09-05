// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation
import Combine
import AVFoundation
import MediaPlayer
import UIKit

/// Sleep timer (fixed minutes / until chapter end) incl. volume fade.
extension PlayerViewModel {

    // MARK: - Sleep timer

    /// Fades out in the last seconds; on timer end pause and reset the volume
    /// for the next playback.
    private func applySleepFade(remaining: Double) {
        guard remaining < sleepFadeDuration else { return }
        player?.volume = Float(max(0, remaining / sleepFadeDuration))
    }

    private func finishSleepTimer() {
        pause()
        player?.volume = 1
        sleepTimerRemaining = nil
        sleepUntilChapterEnd = false
        sleepUntilTrackEnd = false
    }

    func startSleepTimer(minutes: Double) {
        // Remembered HERE, at the one place a clock duration is started, so
        // every caller feeds it and none has to think of it.
        AppStorageKeys.rememberSleepTimer(minutes: minutes)
        sleepTask?.cancel()
        player?.volume = 1
        sleepUntilChapterEnd = false
        sleepUntilTrackEnd = false
        sleepTimerRemaining = minutes * 60
        // Count only while actually LISTENING. Pausing freezes the timer (its
        // purpose is "stop after X minutes of listening", not wall-clock time).
        runSleepTicks { vm in
            guard let remaining = vm.sleepTimerRemaining else { return nil }
            return vm.isPlaying ? remaining - 1 : remaining
        }
    }

    /// The one tick loop of every sleep mode: once a second the mode says
    /// what is left (nil ends the loop), the loop shows it, fades and
    /// finishes. A value that did not move (paused) is not written again.
    private func runSleepTicks(_ remainingNow: @escaping @MainActor (PlayerViewModel) -> Double?) {
        sleepTask = Task { [weak self] in
            while let self, !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                if Task.isCancelled { break }
                guard let remaining = remainingNow(self) else { break }
                if self.sleepTimerRemaining != remaining { self.sleepTimerRemaining = remaining }
                self.applySleepFade(remaining: remaining)
                if remaining <= 0 {
                    self.finishSleepTimer()
                    break
                }
            }
        }
    }

    func cancelSleepTimer() {
        sleepTask?.cancel()
        player?.volume = 1
        sleepTimerRemaining = nil
        sleepUntilChapterEnd = false
        sleepUntilTrackEnd = false
    }

    /// Extends the running timer by the given minutes. End-of-chapter/track
    /// modes are converted into a fixed countdown (current remaining + extra).
    func extendSleepTimer(byMinutes minutes: Double) {
        guard let remaining = sleepTimerRemaining else { return }
        startSleepTimer(minutes: (remaining + minutes * 60) / 60)
    }

    /// Sleep until the end of the CURRENT track (multi-file books). Same
    /// mechanics as the chapter-end mode, different boundary.
    func startSleepTimerUntilTrackEnd() {
        sleepTask?.cancel()
        guard let end = currentTrackEndTime() else {
            sleepUntilTrackEnd = false
            return
        }
        sleepUntilChapterEnd = false
        sleepUntilTrackEnd = true
        player?.volume = 1
        sleepTimerRemaining = max(end - currentTime, 0)
        runSleepTicks { vm in max(end - vm.currentTime, 0) }
    }

    /// Sleep timer until the end of the current chapter. Instead of fixed
    /// minutes, playback runs to the chapter boundary and then pauses.
    func startSleepTimerUntilChapterEnd() {
        sleepTask?.cancel()
        guard let chapter = currentChapter else {
            sleepUntilChapterEnd = false
            return
        }
        sleepUntilChapterEnd = true
        sleepUntilTrackEnd = false
        player?.volume = 1
        let end = chapter.end
        sleepTimerRemaining = max(end - currentTime, 0)
        runSleepTicks { vm in max(end - vm.currentTime, 0) }
    }
}
