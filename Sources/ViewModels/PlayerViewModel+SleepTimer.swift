import Foundation
import Combine
import AVFoundation
import MediaPlayer
import UIKit

/// Sleep-Timer (feste Minuten / bis Kapitelende) inkl. Lautstärke-Fade.
extension PlayerViewModel {

    // MARK: - Sleep-Timer

    /// Blendet in den letzten Sekunden aus; beim Timer-Ende pausieren und die
    /// Lautstärke fürs nächste Abspielen zurücksetzen.
    private func applySleepFade(remaining: Double) {
        guard remaining < sleepFadeDuration else { return }
        player?.volume = Float(max(0, remaining / sleepFadeDuration))
    }

    private func finishSleepTimer() {
        pause()
        player?.volume = 1
        sleepTimerRemaining = nil
        sleepUntilChapterEnd = false
    }

    func startSleepTimer(minutes: Double) {
        sleepTask?.cancel()
        player?.volume = 1
        sleepUntilChapterEnd = false
        sleepTimerRemaining = minutes * 60
        sleepTask = Task { [weak self] in
            while let self, !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                if Task.isCancelled { break }
                guard var remaining = self.sleepTimerRemaining else { break }
                remaining -= 1
                self.sleepTimerRemaining = remaining
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
    }

    /// Sleep-Timer bis zum Ende des aktuellen Kapitels. Statt fester Minuten
    /// läuft die Wiedergabe bis zur Kapitelgrenze und pausiert dann.
    func startSleepTimerUntilChapterEnd() {
        sleepTask?.cancel()
        guard let chapter = currentChapter else {
            sleepUntilChapterEnd = false
            return
        }
        sleepUntilChapterEnd = true
        player?.volume = 1
        let end = chapter.end
        sleepTimerRemaining = max(end - currentTime, 0)
        sleepTask = Task { [weak self] in
            while let self, !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                if Task.isCancelled { break }
                let remaining = max(end - self.currentTime, 0)
                self.sleepTimerRemaining = remaining
                self.applySleepFade(remaining: remaining)
                if remaining <= 0 {
                    self.finishSleepTimer()
                    break
                }
            }
        }
    }
}
