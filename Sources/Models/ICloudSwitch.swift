// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation

/// What the iCloud switch in the sync settings shows. The way that carries
/// is visible: with the Mär sync service set up, iCloud stands visibly off
/// and locked, never both at once and never a silent sign-out by a switch.
/// Without the service the switch IS the one switch for travelling over
/// iCloud.
///
/// Derived from what the carriers actually chose in this run
/// (`CarrierChoices`), not from a second flag: carriers choose when they are
/// built, so right after a sign-in the old ones still use iCloud until the
/// next start, and the switch says so.
nonisolated enum ICloudSwitch {
    enum State: Equatable, Sendable {
        /// No service: the switch carries the travelling itself.
        case free
        /// The service carries: no carrier of this run holds iCloud, also
        /// when none is built yet (every one built from now takes the
        /// service).
        case lockedServiceCarries
        /// The service is set up; carriers built before still use iCloud
        /// until the next start.
        case lockedFromNextStart
    }

    static func state(serviceConfigured: Bool, anyCarrierHoldsICloud: Bool) -> State {
        guard serviceConfigured else { return .free }
        return anyCarrierHoldsICloud ? .lockedFromNextStart : .lockedServiceCarries
    }
}
