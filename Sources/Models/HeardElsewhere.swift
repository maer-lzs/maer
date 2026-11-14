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
    /// as not finished before. The answer before decides for a title it
    /// names; for one it does not name, `held` decides: the titles the last
    /// answer of an earlier run held as not finished (`HeldUnfinished`), so
    /// a title finished elsewhere while the app was closed counts too. A
    /// title neither names stays out: a finished title in the first answer
    /// is no change anyone made. Sorted, so a log line and a witness read
    /// the same order.
    static func newlyFinished(before: [String: BookProgress], after: [String: BookProgress],
                              held: Set<String> = []) -> [String] {
        after.compactMap { id, progress in
            guard progress.countsAsFinished else { return nil }
            if let old = before[id] { return old.countsAsFinished ? nil : id }
            return held.contains(id) ? id : nil
        }.sorted()
    }

    /// The titles an answer names as not finished: what the next run
    /// compares its first answer with.
    static func unfinished(_ progress: [String: BookProgress]) -> Set<String> {
        Set(progress.compactMap { id, entry in entry.countsAsFinished ? nil : id })
    }
}
