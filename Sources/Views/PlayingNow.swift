// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation

/// Which title plays right now, here or on the other device. The rows and
/// the cards ask THIS, so "playing" means the same thing in both.
@MainActor
enum PlayingNow {
    /// The moment to use for a title that plays: now. Nil when it does not.
    /// A foreign claim counts only while it is fresh; the runner resolves
    /// that at its clock (`hint`), and the rule is asked once more here so
    /// a moment handed in by a witness still decides.
    static func momentMs(forId id: String, nowMs: Double = Date().timeIntervalSince1970 * 1000) -> Double? {
        let coordinator = AppSession.shared.playerCoordinator
        if coordinator.activeItem?.id == id, coordinator.viewModel?.isPlaying == true { return nowMs }
        guard let claim = PlaybackClaimRules.hintClaim(
                  claim: PlaybackClaimSync.shared.hint,
                  ownDeviceId: SyncHistoryStore.deviceId, nowMs: nowMs),
              claim.itemId == id else { return nil }
        return nowMs
    }
}
