// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation

/// Where a detail page takes its tracks from, pure. What is downloaded is
/// complete on the device: the detail stored with the download names every
/// track, artist and length. The album and playlist page asked the network
/// every time and never the store, so a downloaded playlist played offline
/// while its page showed a load error. The player has read the store first
/// all along (`PlayerCoordinator.open`); the page now does the same.
nonisolated enum DetailLoadPlan: Equatable {
    /// Show the stored detail at once; refresh from the network when there
    /// is one. A failed refresh keeps what is shown.
    case stored(refresh: Bool)
    /// Nothing stored: the network answers.
    case network
    /// Nothing stored and no network: "not available offline", never a
    /// transport error and never a request that cannot succeed.
    case offlineMissing

    static func decide(hasStored: Bool, isConnected: Bool) -> DetailLoadPlan {
        if hasStored { return .stored(refresh: isConnected) }
        return isConnected ? .network : .offlineMissing
    }

    /// Whether a refresh answer replaces what is shown. An answer WITH
    /// tracks does; an empty one never replaces a stored detail that has
    /// tracks: those files are on the device and play, and a server that
    /// answers empty for a moment took the downloaded playlist's page to
    /// "no tracks" online while it showed them offline. Without a stored
    /// detail the empty answer is the page's truth and says so.
    static func adopts(fetchedTrackCount: Int, storedTrackCount: Int?) -> Bool {
        guard fetchedTrackCount == 0, let storedTrackCount else { return true }
        return storedTrackCount == 0
    }
}
