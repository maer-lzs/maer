// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation

/// Whether a track row of an album or a playlist is the song that plays.
/// One answer for the album page, the server playlist and the device
/// playlist, so the mark means the same thing on all three.
nonisolated enum TrackPlaying {
    /// What a row knows about itself.
    struct Row: Equatable {
        /// The entry the row is a song of (an album or a server playlist),
        /// with the song's start inside it; nil for a row that is its own
        /// entry.
        var entryId: String?
        var start: Double?
        /// The row's own playable id: the song's item id, or on a device
        /// playlist the entry itself.
        var ownId: String?
    }

    /// The row plays when the session plays its own id (a song started on
    /// its own, a device playlist entry), or plays its entry with the
    /// current chapter starting where the row starts.
    static func isCurrent(_ row: Row, playingId: String?, playingChapterStart: Double?) -> Bool {
        guard let playingId else { return false }
        if let own = row.ownId, own == playingId { return true }
        guard let entry = row.entryId, entry == playingId,
              let start = row.start, let at = playingChapterStart else { return false }
        return abs(start - at) < 0.5
    }
}
