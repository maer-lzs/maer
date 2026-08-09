// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation

/// The rules for tidying up after the automatic download — the part that must
/// be provable without a screen.
///
/// The binding condition: **the cleanup only ever touches what the automatism
/// itself downloaded.** That is a property of the DATA (an id the automatism
/// recorded), never a guess from the age of a file — someone who downloaded an
/// episode by hand for a flight must not lose it because a background pass
/// thought it looked old.
///
/// Deliberately source-neutral: nothing here knows what a podcast is, so the
/// same rules can carry "keep this playlist offline" later.
nonisolated enum PodcastAutoDownloadRules {
    /// How long a finished download stays before it goes. A week, because
    /// "finished" is not "never again" — re-listening on the train is normal,
    /// and the file is worthless offline once it is gone.
    static let keepAfterFinish: TimeInterval = 7 * 24 * 3600

    struct Item: Equatable, Sendable {
        let id: String
        let isFinished: Bool
        /// When the finished state was last written (seconds since 1970).
        let finishedAt: Double

        init(id: String, isFinished: Bool, finishedAt: Double) {
            self.id = id
            self.isFinished = isFinished
            self.finishedAt = finishedAt
        }
    }

    /// Which downloads may go now — never anything outside `ownedByAutomation`.
    static func expired(_ items: [Item],
                        ownedByAutomation: Set<String>,
                        now: Double,
                        keepFor: TimeInterval = keepAfterFinish) -> [String] {
        items.filter { item in
            ownedByAutomation.contains(item.id)
                && item.isFinished
                && item.finishedAt > 0
                && now - item.finishedAt >= keepFor
        }.map(\.id)
    }

    /// Ids the automatism no longer has to remember: everything it deleted,
    /// plus everything that is not on the device any more (deleted by hand —
    /// the note would otherwise grow forever).
    static func forget(ownedByAutomation: Set<String>,
                       deleted: [String],
                       stillDownloaded: Set<String>) -> Set<String> {
        ownedByAutomation.subtracting(deleted).intersection(stillDownloaded)
    }
}
