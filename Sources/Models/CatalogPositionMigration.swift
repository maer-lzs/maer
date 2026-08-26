// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation

/// Which song a stored ALBUM position belongs to, and what to write there.
///
/// The decision used to sit inside the migration together with a network fetch
/// and two defaults accesses, so it could only be checked against entries the
/// app had just written itself. That is the blind spot the stock repair ran
/// into: an IMPORTED stock. Many entries at once, identical timestamp, no
/// reference point. Is the normal case for a new user and was tested by
/// nobody. Pure here, so exactly that case can be fed to it.
nonisolated enum CatalogPositionMigration {
    /// `nil` = nothing to carry over. Never invents an entry, never overwrites
    /// one: where the song already has a position, the album's is not the
    /// better knowledge.
    ///
    /// The timestamp travels along unchanged. The moment of listening is what
    /// it was, and every merge in the app decides by it. A migration that
    /// stamps "now" would make the copy win against the very entry it came
    /// from.
    static func songEntry(albumPosition stored: [Double],
                          tracks: [ABSAudioTrack],
                          songAlreadyHasEntry: Bool) -> (index: Int, entry: [Double])? {
        guard !songAlreadyHasEntry,
              stored.count >= 2, let position = stored.first, position > 0,
              let index = FreeCatalog.trackIndex(at: position, tracks: tracks),
              index < tracks.count else { return nil }
        let within = position - (tracks[index].startOffset ?? 0)
        return (index, ProgressMark.entry(position: max(0, within),
                                          duration: tracks[index].duration ?? 0,
                                          nowMs: ProgressMark.timestamp(stored) ?? 0))
    }
}
