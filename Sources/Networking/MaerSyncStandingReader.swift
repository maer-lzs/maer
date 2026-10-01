// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation

/// The inputs of `MaerSyncStanding`, read in one place, so the map row and
/// the service's page say the same thing. The access is read through its one
/// reader (`MaerSyncAccess.stored()`); the carriers through the register
/// they write; the session's refusals from the session. Reading never
/// creates a runner.
@MainActor
enum MaerSyncStandingReader {
    struct Now: Equatable {
        let standing: MaerSyncStanding
        let host: String?
    }

    static func current() -> Now {
        PerfSignpost.standingRead()
        let access = MaerSyncAccess.stored()
        let session = MaerSyncCarriers.session
        let standing = MaerSyncStanding.standing(
            syncAcrossDevices: AppStorageKeys.syncAcrossDevicesEnabled,
            carrierIsTheService: CarrierChoices.anyTravelsTheService,
            signedIn: access != nil,
            tokenRefused: session.unauthorized,
            serviceOlder: session.serviceOlder)
        return Now(standing: standing, host: access?.baseURL.host())
    }
}
