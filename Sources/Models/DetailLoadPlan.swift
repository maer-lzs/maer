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
}
