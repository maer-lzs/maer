// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation

/// What the sync service page may say about itself.
///
/// The page used to read the SETTING and say "what is set up here is in
/// use". The carriers are chosen once, in the runners' `init`, so someone
/// who sets the service up while the app runs gets that confirmation while
/// everything still travels the old way until the next cold start. A
/// sentence about the arrangement, read as a sentence about the operation,
/// and the person cannot tell the two apart.
///
/// So the page asks what a runner really HOLDS. **And since 16.09.2026 it
/// also asks whether that carrier can still carry**, because the two are
/// not the same question and the gap between them was the worst state this
/// page could be in:
///
/// Signing out empties the access; every read and write of the session
/// leaves at its `guard let access`. The runner still holds the SERVICE
/// carrier until the app restarts. So nothing travels to the service
/// (there is no access) and nothing travels to Apple either (the carrier
/// is the service's). **Positions, playlists, choices and statistics all
/// stand still, and the page said "what is set up here is in use".**
///
/// The rule was not built wrong; it was missing an input. It asked WHICH
/// carrier was chosen and never whether it could still do anything.
nonisolated enum MaerSyncStanding: Equatable {
    /// The one switch above every carrier is off. Nothing travels, no
    /// matter what is set up here.
    case switchedOff
    /// The service carries, now.
    case carrying
    /// It is set up and the switch is on, but a runner still holds the
    /// carrier it was given at start-up.
    case fromTheNextStart
    /// **Signed out while the app kept running.** The runner still holds
    /// the service, and the service has no access: nothing travels at all,
    /// in either direction, until the app restarts. The one state where
    /// saying nothing would be worse than saying something awkward.
    case stalledUntilRestart
    /// Not signed in, and no runner holds the service. This service is
    /// simply not the way here; Apple carries, as it did before.
    case notInUse

    static func standing(syncAcrossDevices: Bool,
                         carrierIsTheService: Bool,
                         signedIn: Bool) -> MaerSyncStanding {
        // The switch stands above everything, as everywhere else.
        guard syncAcrossDevices else { return .switchedOff }
        switch (carrierIsTheService, signedIn) {
        case (true, true): return .carrying
        case (true, false): return .stalledUntilRestart
        case (false, true): return .fromTheNextStart
        case (false, false): return .notInUse
        }
    }

    /// Whether anything at all is travelling right now, over any carrier.
    ///
    /// Kept beside the sentence rather than derived at the call site: the
    /// page shows a sentence and the answer to this question has to be the
    /// SAME reading, or the two drift apart the way the sentence and the
    /// operation did.
    var somethingTravels: Bool {
        switch self {
        case .carrying, .fromTheNextStart, .notInUse: return true
        case .switchedOff, .stalledUntilRestart: return false
        }
    }
}
