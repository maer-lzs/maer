// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import SwiftUI

/// Whether the app can reach the network right now, as a VALUE.
///
/// Every surface that dims a row, hides a download menu or skips a fetch
/// used to reach `NetworkMonitor.shared` itself, which makes it untestable
/// and unpreviewable with anything else in that seat. Now ONE observer at
/// the root hands the answer down and sixteen leaves lose their own
/// subscription: net one less, not sixteen.
///
/// That one observer sits at the OUTERMOST view, which is normally the shape
/// this project forbids: a container that observes invalidates everything
/// below it. The exception holds for exactly one reason, and it is a
/// measurable one rather than a preference: the rule is "frequently changing
/// means it can change during a gesture", and a network change never does.
/// It carries a CONDITION, and a fence holds it instead of a comment:
/// `@ObservedObject` reacts to the object, not to a field, so a SECOND
/// published property on the monitor would invalidate the whole tree on
/// every change of it while the online answer stands still.
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
