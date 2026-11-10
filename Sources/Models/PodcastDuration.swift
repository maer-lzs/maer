// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation

/// The length of an episode as the stock holds it.
nonisolated enum PodcastDuration {
    /// The longest length taken as known, in seconds: one year. A longer
    /// one does not fit the whole numbers the rows and the server writes
    /// convert it to.
    static let longest: Double = 366 * 86_400

    /// A length from a feed, a directory or a stored row: finite, not
    /// negative and no longer than `longest`. Anything else is 0, which
    /// every reader takes as unknown.
    static func known(_ raw: Double) -> Double {
        raw.isFinite && raw >= 0 && raw <= longest ? raw : 0
    }
}
