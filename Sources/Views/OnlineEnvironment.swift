// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import SwiftUI

/// Whether the app can reach the network right now, as a VALUE.
///
/// Every surface that dims a row, hides a download menu or skips a fetch
/// used to reach `NetworkMonitor.shared` itself, which makes it untestable
/// and unpreviewable with anything else in that seat. The root already
/// observes the monitor for its own tab bar, so handing the value down
/// creates no new observer: the reading leaves lose their own subscription
/// and read a value instead.
///
/// The default is ONLINE. A surface that never gets the value must behave
/// like today rather than start dimming everything; the offline gates only
/// dim, disable and skip, so the optimistic default is the safe direction.
/// That the value is really handed down is held by a fence, not by hope.
private struct OnlineKey: EnvironmentKey {
    static let defaultValue = true
}

extension EnvironmentValues {
    var isOnline: Bool {
        get { self[OnlineKey.self] }
        set { self[OnlineKey.self] = newValue }
    }
}
