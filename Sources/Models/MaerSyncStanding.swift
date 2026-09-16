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
/// So the page asks what a runner really HOLDS, and this rule turns the
/// two facts into one of three sentences.
nonisolated enum MaerSyncStanding: Equatable {
    /// The one switch above every carrier is off. Nothing travels, no
    /// matter what is set up here.
    case switchedOff
    /// The service carries, now.
    case carrying
    /// It is set up and the switch is on, but a runner still holds the
    /// carrier it was given at start-up.
    case fromTheNextStart

    static func standing(syncAcrossDevices: Bool, carrierIsTheService: Bool) -> MaerSyncStanding {
        guard syncAcrossDevices else { return .switchedOff }
        return carrierIsTheService ? .carrying : .fromTheNextStart
    }

    /// Whether a carrier name belongs to the service. The name is compared
    /// against the stem the session itself answers with, never against a
    /// spelling written down twice.
    static func isTheService(carrierName: String, stem: String) -> Bool {
        carrierName.hasPrefix(stem)
    }
}
