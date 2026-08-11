// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation

/// May a load start right now? The whole rule, in one value.
///
/// Reading the catalogue rows starts their load — a surface that reads without
/// fetching is not expressible. That is right, and it is exactly why the
/// question "may I start" must not be answered with "did content arrive":
///
/// **An empty pass is a pass.** While the trigger asked whether CONTENT had
/// arrived, every pass that came back empty left the answer at "no": the next
/// body evaluation started another load, its result was published, the publish
/// re-rendered the view, the render read the rows again — a loop that fed
/// itself. The app kept drawing and stopped reacting: taps went nowhere,
/// context menu items were no longer hittable.
///
/// So this gate counts ATTEMPTS, not yields. A new attempt is opened by the
/// explicit paths only — pull to refresh, the error line's retry, a language
/// change, or the network coming back.
nonisolated struct CatalogLoadGate: Equatable, Sendable {
    private(set) var attempted = false
    private(set) var loading = false

    init() {}

    /// Start a pass? Offline is NOT an attempt — nothing runs, so nothing was
    /// tried, and the first read after the network returns starts one.
    mutating func startIfNeeded(connected: Bool) -> Bool {
        guard connected, !attempted, !loading else { return false }
        attempted = true
        loading = true
        return true
    }

    /// A pass that an explicit caller runs itself (pull to refresh, the page's
    /// own task). Same bookkeeping, same one-at-a-time rule.
    mutating func beginExplicit() -> Bool {
        guard !loading else { return false }
        attempted = true
        loading = true
        return true
    }

    mutating func finish() { loading = false }

    /// Open a new attempt — the language changed, the user asked again, or the
    /// network came back.
    mutating func reopen() { attempted = false }
}
