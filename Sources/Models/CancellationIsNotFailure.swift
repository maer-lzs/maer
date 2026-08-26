// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation

/// The ONE answer to "was this run cancelled?" — because five
/// instances of the throw-is-not-the-end class meant there was a sixth, and
/// the sweep found EIGHT more `catch` sites booking a cancelled run as a
/// failure (`failed = true` on an intact network).
///
/// A `.task(id:)` restart, a view leaving the tree, a pull-to-refresh — all of
/// them cancel the run in flight, and the restarted task loads the real answer
/// a moment later. Booking the cancellation shows "check your connection" over
/// a working network (GT R6b, measured). The rule lives here once; every load
/// path asks it BEFORE booking a failure.
nonisolated extension Error {
    /// True for Swift task cancellation and URLSession's cancelled code —
    /// the two shapes the same event arrives in.
    var isCancellation: Bool {
        if self is CancellationError { return true }
        if let urlError = self as? URLError, urlError.code == .cancelled { return true }
        return false
    }
}
