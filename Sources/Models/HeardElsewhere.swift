// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation

/// A played mark that comes from elsewhere (another device, gpodder, an
/// import, the server) takes the title out of Up Next, as the device's own
/// mark does. Only the change counts: a title that was played before the
/// adoption and is played after it stays where it is, so one the person put
/// back into Up Next on purpose is not taken out by every later sync. Pure.
nonisolated enum HeardElsewhere {
    /// A listening entry, before or after the adoption, judged by the same
    /// rule the episode rows ask (`ProgressMark.state` with the title's
    /// tail). No entry is not played: the stand of this device is kept on
    /// the device.
    static func isPlayed(_ entry: [Double]?, duration: Double, tail: Double) -> Bool {
        ProgressMark.state(stored: entry, currentDuration: duration, tail: tail) == .played
    }

    static func became(wasPlayed: Bool, isPlayed: Bool) -> Bool {
        isPlayed && !wasPlayed
    }

    /// The titles a server's progress now counts as finished that it held
    /// as not finished before. A title the answer before did not name stays
    /// out: after a start the first answer is all there is, and a finished
    /// title in it is no change anyone made. Sorted, so a log line and a
    /// witness read the same order.
    static func newlyFinished(before: [String: BookProgress], after: [String: BookProgress]) -> [String] {
        after.compactMap { id, progress in
            guard progress.countsAsFinished, let old = before[id], !old.countsAsFinished else { return nil }
            return id
        }.sorted()
    }
}
