// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation

/// The ONE answer to "was this run cancelled?". Because five
/// instances of the throw-is-not-the-end class meant there was a sixth, and
/// the sweep found EIGHT more `catch` sites booking a cancelled run as a
/// failure (`failed = true` on an intact network).
///
/// A `.task(id:)` restart, a view leaving the tree, a pull-to-refresh. All of
/// them cancel the run in flight, and the restarted task loads the real answer
/// a moment later. Booking the cancellation shows "check your connection" over
/// a working network (measured on the device). The rule lives here once; every load
/// path asks it BEFORE booking a failure.
nonisolated extension Error {
    /// True for Swift task cancellation and URLSession's cancelled code.
    /// The two shapes the same event arrives in.
    var isCancellation: Bool {
        if self is CancellationError { return true }
        if let urlError = self as? URLError, urlError.code == .cancelled { return true }
        return false
    }

    /// True for a request that ended before anything was asked: a lookup
    /// in its holdback (`FetchHeldBack`), a host resting after it said
    /// "not now" (`HostCourtesy.Resting`). Such an end is no failure and no
    /// finding: it books no question, starts no holdback and logs as held.
    /// Before, each place that books kept its own list of such errors, and
    /// a new one (the resting host) was booked as a failure everywhere.
    var endedUnasked: Bool {
        self is any EndedUnasked
    }
}

/// An error that says: nothing was asked. Every such error takes this
/// protocol, so the places that book ask `endedUnasked` and never list
/// names.
nonisolated protocol EndedUnasked: Error {}
