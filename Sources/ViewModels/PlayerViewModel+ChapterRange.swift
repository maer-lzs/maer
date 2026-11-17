// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation
import OSLog

/// A chapter of the loaded book played as an entry of Up Next: the player
/// starts it where `ChapterEntryRules.startPoint` says and reports its end
/// once. The rule is `ChapterEntryRules.state`; the clock asks it at every
/// move of `currentTime`, so the range needs no timer of its own.
extension PlayerViewModel {
    /// Calls `onEnd` once when playback reaches the chapter's end; a move out
    /// of the chapter ends the watch without it, and the book plays on as a
    /// book. A new watch, a stop or a new title ends the old one.
    func watchChapterRange(_ chapter: ABSChapter, onEnd: @escaping @MainActor () -> Void) {
        playsChapterEntry = true
        chapterRange = (chapter, onEnd, false)
    }

    /// What the clock asks at every move while a range is watched.
    func checkChapterRange() {
        guard let range = chapterRange else { return }
        let state = ChapterEntryRules.state(at: currentTime, of: range.chapter)
        if range.ended {
            // After its end the entry holds only the stand at the chapter's
            // end; once the clock moves on, by playing on or by a jump, the
            // book plays as a book again and its own end finishes it.
            if state != .ended { endChapterEntry() }
            return
        }
        switch state {
        case .running:
            return
        case .left:
            Logger.player.notice("CHAPTER entry left: the book plays on")
            endChapterEntry()
        case .ended:
            chapterRange?.ended = true
            range.onEnd()
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
        await syncProgress(.chapterEntry)
    }

    /// Ends the watch and the entry, when another title takes over or the
    /// player stops.
    func endChapterEntry() {
        chapterRange = nil
        playsChapterEntry = false
    }
}
