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
/// The runners follow a sign-in at once (`AccessFollowers`), so with the
/// service set up no carrier of this run holds iCloud.
nonisolated enum ICloudSwitch {
    enum State: Equatable, Sendable {
        /// No service: the switch carries the travelling itself.
        case free
        /// The service carries.
        case lockedServiceCarries
    }

    static func state(serviceConfigured: Bool) -> State {
        serviceConfigured ? .lockedServiceCarries : .free
    }
}
