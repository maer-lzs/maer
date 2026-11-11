// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation

/// A removal from a server playlist goes by position, the position of the
/// row the person swiped. It goes out only while the server's list still
/// holds the same song at every such position; otherwise another song
/// would fall (a reload that failed, a second swipe before the reload).
nonisolated enum PlaylistRemoval {
    /// The removal stopped because the list changed under the rows shown.
    struct Changed: Error, Equatable {}

    /// Whether every position still holds the song the row showed. A row
    /// whose song is not known (the list was dropped after a removal and
    /// not drawn again) is no proof and stops the removal.
    static func stillAt(_ indices: [Int], drawn: [String?], current: [String]) -> Bool {
        guard !indices.isEmpty, drawn.count == indices.count else { return false }
        return zip(indices, drawn).allSatisfy { index, song in
            guard let song, current.indices.contains(index) else { return false }
            return current[index] == song
        }
    }
}
