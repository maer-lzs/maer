// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation

/// The one switch for drive mode. Closed, no entry reaches it: the player's
/// tool, the Siri and Shortcuts phrase, the start when the car's audio
/// connects (also with the stored toggle on) and the settings section. The
/// mode's code stays in place.
nonisolated enum DriveModeGate {
    static let isOpen = false
}
