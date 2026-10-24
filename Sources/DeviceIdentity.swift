// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import UIKit

/// This device, by the name the system hands out. Without the entitlement
/// `com.apple.developer.device-information.user-assigned-device-name` (not
/// granted; measured 05.09.2026) that is "iPhone" or "iPad", never the name
/// the person gave the device. The ONE place UIKit is asked; the sync
/// carriers in Networking take the name as an input and stay UI-free.
enum DeviceIdentity {
    static var name: String {
        // The one question "runs on a Mac" (iPad app on the Mac and Catalyst).
        name(system: UIDevice.current.name, onMac: PlatformIdiom.isAppOnMac)
    }

    /// The name for the other devices. On a Mac the app runs as an iPad app
    /// and the system says "iPad"; the takeover notice on the other devices
    /// then named the Mac an iPad. The Mac is called "Mac", as general as
    /// the system's "iPhone" and "iPad".
    nonisolated static func name(system: String, onMac: Bool) -> String {
        onMac ? "Mac" : system
    }
}
