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
}
