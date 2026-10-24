// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation

/// When the side column shows the settings cog: only at the tab's root. On a
/// pushed page the system stands its back button in the same place, so the
/// two must never be there at once. Leaving the root hides the cog at once,
/// before the back button slides in; coming back shows it only after the
/// back button has gone.
nonisolated enum SideColumnCog {
    /// Longer than the system's pop, so the back button has left the column
    /// before the cog fades in.
    static let afterPop: Double = 0.5

    /// What the cog does when the active tab arrives at, or leaves, its root:
    /// whether it shows, and how long it waits first.
    static func step(atRoot: Bool) -> (visible: Bool, after: Double) {
        atRoot ? (true, afterPop) : (false, 0)
    }
}
