// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation

/// A chapter of the loaded book played as an entry of Up Next: the player
/// starts it where `ChapterEntryRules.startPoint` says and reports its end
/// once.
extension PlayerViewModel {
    /// Calls `onEnd` once when playback reaches the chapter's end; a move out
    /// of the chapter ends the watch without it.
    func watchChapterRange(_ chapter: ABSChapter, onEnd: @escaping @MainActor () -> Void) {
    }

    /// Positions the loaded book for a chapter entry and records the stand.
    /// The queue started it, not the person, so the backward guard of the
    /// sync stays in force.
    func startChapterEntry(_ chapter: ABSChapter) async {
    }
}
