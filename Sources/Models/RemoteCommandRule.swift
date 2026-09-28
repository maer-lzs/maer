// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation

/// Which remote commands (lock screen, Control Center, CarPlay, headphone
/// presses) are on for what is playing, decided per item so a switch from a
/// song to an episode in one queue needs no re-registration.
///
/// Music is a list of songs: the title commands move between them, and the
/// skip-by-seconds commands are off, as in the system's own music app. Books,
/// podcasts and catalogue works keep both (a title press there is the set
/// skip, decided earlier). A live stream has nothing to skip or move to.
nonisolated enum RemoteCommandRule {
    struct Enabled: Equatable, Sendable {
        let skip: Bool
        let track: Bool
    }

    static func enabled(for family: MediaFamily) -> Enabled {
        switch family {
        case .radio: return Enabled(skip: false, track: false)
        case .music: return Enabled(skip: false, track: true)
        case .book, .podcast, .catalog, .unknown: return Enabled(skip: true, track: true)
        }
    }
}
