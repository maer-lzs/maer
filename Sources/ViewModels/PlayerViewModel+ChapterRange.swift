// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation
import OSLog

/// A chapter of the loaded book played as an entry of Up Next: the player
/// starts it where `ChapterEntryRules.startPoint` says and reports its end
/// once. The rule is `ChapterEntryRules.state`; this only reads the clock
/// once a second, as the sleep timer does.
extension PlayerViewModel {
    /// Calls `onEnd` once when playback reaches the chapter's end; a move out
    /// of the chapter ends the watch without it, and the book plays on as a
    /// book. A new watch, a stop or a new title ends the old one.
    func watchChapterRange(_ chapter: ABSChapter, onEnd: @escaping @MainActor () -> Void) {
        chapterRangeTask?.cancel()
        playsChapterEntry = true
        chapterRangeTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard !Task.isCancelled, let self else { return }
                switch ChapterEntryRules.state(at: self.currentTime, of: chapter) {
                case .running:
                    continue
                case .left:
                    Logger.player.notice("CHAPTER entry left: the book plays on")
                    self.playsChapterEntry = false
                    self.chapterRangeTask = nil
                    return
                case .ended:
                    // The stand at the chapter's end is still the entry's, so
                    // the flag stays until the next title loads.
                    self.chapterRangeTask = nil
                    onEnd()
                    return
                }
            }
        }
    }

    /// Positions the loaded book for a chapter entry and records the stand.
    /// The queue started it, not the person, so the backward guard of the
    /// sync stays in force: a chapter before the server's stand raises the
    /// conflict instead of writing over it.
    func startChapterEntry(_ chapter: ABSChapter) async {
        playsChapterEntry = true
        let start = ChapterEntryRules.startPoint(of: chapter, bookPosition: currentTime)
        await seek(to: start, userInitiated: false)
        await syncProgress(.seek)
    }

    /// Ends the watch and the entry, when another title takes over or the
    /// player stops.
    func endChapterEntry() {
        chapterRangeTask?.cancel()
        chapterRangeTask = nil
        playsChapterEntry = false
    }
}
