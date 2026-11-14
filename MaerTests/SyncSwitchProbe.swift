// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Foundation
@testable import Maer

/// The switch under which the carriers talk at all, as an ASSERTION
/// instead of a hope.
///
/// Four witnesses began with `guard AppStorageKeys.syncAcrossDevicesEnabled
/// else { return }`. That is no skipping: if the default is off,
/// the case reports PASSED and has measured nothing, and a green run
/// without a measurement is the most expensive outcome.
///
/// The default is process-wide, and two neighbouring suites set exactly it to
/// off. They put it back, but once without `defer`: if the case breaks
/// in between, the switch stays down, and every later witness with the
/// guard above passes from then on without measuring. None of these suites is
/// `.serialized`, so the order is fixed nowhere.
///
/// That is why the switch is SET here and afterwards restored exactly as
/// it was, instead of being read.
@MainActor
enum SyncSwitchProbe {
    /// Flips the switch and returns how it is put back.
    ///
    /// The return value instead of a block around the whole case is deliberate: it
    /// costs the witnesses two lines instead of an indentation, and a
    /// `defer` beside it reads like any other cleanup line in the case.
    static func armOn() -> @MainActor () -> Void {
        let key = AppStorageKeys.podcastICloudSync
        let was = UserDefaults.standard.object(forKey: key)
        UserDefaults.standard.set(true, forKey: key)
        return {
            if let was { UserDefaults.standard.set(was, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
        }
    }
}
#endif
