// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation

/// Whether a download's progress report goes out to the views.
///
/// URLSession reports every chunk, and every publish of the download phase
/// re-runs every view that observes the download manager. So only meaningful
/// steps go out: a fraction that moved by at least `step` since the last one
/// that went out, the end, and the switch to "size unknown" once.
///
/// Pure so the number of publishes per download can be counted instead of
/// estimated; the manager keeps the state and applies the outcome.
nonisolated enum ProgressPublishRule {
    enum Outcome: Equatable {
        /// Nothing goes out.
        case skip
        /// The server sent no size: the ring turns into a spinner.
        case indeterminate
        /// This fraction goes out and becomes the last published one.
        case fraction(Double)
    }

    /// The smallest move that is worth a publish: one percent.
    static let step = 0.01

    /// - Parameters:
    ///   - current: the fraction the phase shows now, `nil` when the item is
    ///     not downloading (paused, failed, done or unknown).
    ///   - lastPublished: the last fraction that went out, `nil` before the first.
    ///   - fraction: the new report; below zero means the size is unknown.
    static func outcome(current: Double?, lastPublished: Double?, fraction: Double) -> Outcome {
        guard let current else { return .skip }
        if fraction < 0 {
            return current < 0 ? .skip : .indeterminate
        }
        let last = lastPublished ?? -1
        guard fraction - last >= step || fraction >= 1 else { return .skip }
        return .fraction(fraction)
    }
}
