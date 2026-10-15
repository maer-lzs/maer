// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation

/// When the per-second tick writes the lock screen's info again.
///
/// The system runs the shown time on by itself from the elapsed time and
/// the rate of the last write. So the tick writes only when something but
/// the running time changed (title, subtitle with its chapter, duration,
/// rate, the live treatment, the artwork), or when the time the system runs
/// on has drifted from the real one (a stall, a jump the events did not
/// write). Every event that moves playback writes on its own, as before.
nonisolated enum NowPlayingRefresh {
    /// What the lock screen shows apart from the running time.
    struct Fields: Equatable {
        var title: String
        var subtitle: String
        var duration: Double
        var rate: Double
        var isLive: Bool
        var artwork: ObjectIdentifier?
    }

    /// One written state: the fields, and the elapsed time at the moment
    /// of the write.
    struct Written: Equatable {
        var fields: Fields
        var elapsed: Double
        var at: TimeInterval
    }

    /// How far the time the system runs on may drift before the tick
    /// writes again: the shown time is in whole seconds.
    static let driftTolerance = 1.0

    static func isDue(last: Written?, fields: Fields, elapsed: Double, at now: TimeInterval) -> Bool {
        guard let last, last.fields == fields else { return true }
        // A live stream shows no running time.
        if fields.isLive { return false }
        let runOn = last.elapsed + (now - last.at) * last.fields.rate
        return abs(runOn - elapsed) > driftTolerance
    }
}
