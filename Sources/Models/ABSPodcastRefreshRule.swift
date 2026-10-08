// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation

/// Whether one refresh of the server's podcast shows replaces what the
/// device holds. An empty answer means "no show any more" only when every
/// fetch of the run answered (the person deleted the last show); when a
/// fetch failed and nothing came back, it means nothing and the last state
/// stays. A run that loaded something is taken as before, even with a
/// failed fetch beside it.
nonisolated enum ABSPodcastRefreshRule {
    static func adopts(everyFetchAnswered: Bool, loadedAny: Bool, holdsShows: Bool) -> Bool {
        everyFetchAnswered || loadedAny || !holdsShows
    }

    /// Whether an implicit caller (a mount, a subscription that asks what
    /// the server holds) may start a refresh now: the last adopted answer is
    /// older than `maxAge`, and the last failed run is out of its holdback
    /// (`FetchHoldback`). Without the second half a server that could not be
    /// read was asked again for every feed of a loop.
    static func mayRefresh(lastRefreshAt: Date?, failedAt: Date?, now: Date, maxAge: TimeInterval) -> Bool {
        if let lastRefreshAt, now.timeIntervalSince(lastRefreshAt) < maxAge { return false }
        return FetchHoldback.mayAsk(failedAt: failedAt, now: now)
    }
}
