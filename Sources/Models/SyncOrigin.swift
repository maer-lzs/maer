// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation

/// Why the player writes a position. Every caller of the sync names its
/// occasion; before, only "forced or not" arrived, and a position written on
/// a device could not be traced back to a pause, a seek or the background.
///
/// Two questions decide: `isDeliberate`, every occasion except the timer
/// tick, and `needsOwnStand`, the occasions that write only a stand the
/// device heard itself.
nonisolated enum SyncOrigin: String, CaseIterable, Sendable {
    /// The periodic timer tick while the player is loaded.
    case tick
    /// The audio session was interrupted (a call, another app).
    case interruption
    /// The state restored after a crash is flushed on load.
    case restoreFlush
    /// The item is started over from the beginning.
    case restart
    /// The book reached its end.
    case bookEnd
    case pause
    case seek
    case stop
    /// The app went to the background or became inactive.
    case background
    /// The user confirmed writing a lower position.
    case confirmLower
    /// The user confirmed a series of lock-screen skips.
    case confirmLockscreenJump

    /// A deliberate occasion forces the write: past the five-second
    /// threshold, and as a follow-up round when a write is in flight.
    var isDeliberate: Bool { self != .tick }

    /// The occasions that only carry the stand the device heard: they write
    /// only when it owes one (`SyncState.owesStand`). The person's own acts
    /// (a jump, a restart, a confirmation) write in any state.
    var needsOwnStand: Bool {
        switch self {
        case .pause, .stop, .background, .interruption: return true
        default: return false
        }
    }
}
