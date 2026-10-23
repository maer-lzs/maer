// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation

/// How a deck of tiles fills its last row.
nonisolated enum DeckRows {
    /// A single tile in the last row of a deck with more than one column
    /// takes the full width instead of standing in half of it.
    static func lastSpansAll(count: Int, columns: Int) -> Bool {
        columns > 1 && count > 0 && count % columns == 1
    }
}
