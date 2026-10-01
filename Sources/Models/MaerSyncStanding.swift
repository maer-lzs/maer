// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation

/// What the sync service page may say about itself.
///
/// Signed in is the way the runners take: a sign-in or a sign-out moves
/// every runner built so far onto the carrier of the moment at once
/// (`AccessFollowers`), and every runner built later chooses from the same
/// access. So the access and the way cannot drift apart, and the page reads
/// the access, the switch and the session's refusals.
nonisolated enum MaerSyncStanding: Equatable {
    /// The one switch above every carrier is off. Nothing travels, no
    /// matter what is set up here.
    case switchedOff
    /// The service carries, now.
    case carrying
    /// Not signed in. This service is simply not the way here; Apple
    /// carries, as it did before.
    case notInUse
    /// **The service refused this device's token.** Every round of the
    /// session stops on that until somebody signs in again, and the token
    /// is still in the keychain, so "signed in" read off the keychain was
    /// true while nothing travelled. The one dead end a device cannot
    /// leave on its own, and until 17.09.2026 the page did not show it.
    case tokenRefused
    /// **The service is older than this app**. The rounds stopped
    /// instead of retrying on every occasion; the remedy is on the service,
    /// not on this device.
    case serviceOlder

    static func standing(syncAcrossDevices: Bool,
                         signedIn: Bool,
                         tokenRefused: Bool = false,
                         serviceOlder: Bool = false) -> MaerSyncStanding {
        // The switch stands above everything, as everywhere else.
        guard syncAcrossDevices else { return .switchedOff }
        // An older service answers nothing this app can use, token or not.
        if serviceOlder { return .serviceOlder }
        // A refused token stands above the rest: whatever is set up and
        // whatever a runner holds, the session runs nothing until the
        // person signs in again.
        if tokenRefused { return .tokenRefused }
        return signedIn ? .carrying : .notInUse
    }

    /// Whether anything at all is travelling right now, over any carrier.
    ///
    /// Kept beside the sentence rather than derived at the call site: the
    /// page shows a sentence and the answer to this question has to be the
    /// SAME reading, or the two drift apart the way the sentence and the
    /// operation did.
    var somethingTravels: Bool {
        switch self {
        case .carrying, .notInUse: return true
        case .switchedOff, .tokenRefused, .serviceOlder: return false
        }
    }
}
