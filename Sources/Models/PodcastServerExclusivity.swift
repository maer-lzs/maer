// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// The two podcast SERVER sources — gpodder sync and ABS-podcasts — are mutually
/// exclusive: at most ONE external podcast server at a time. Enabling one forces
/// the other off; disabling one leaves the other alone. Plain RSS
/// (`rssEnabledValue`) is a SEPARATE flag and never touched here — "RSS + one
/// server" stays allowed, "RSS + two servers" does not. Pure, tested; the one
/// place the rule lives (Regel 2), used by the `AppStorageKeys` setters.
nonisolated enum PodcastServerExclusivity {
    enum Source { case gpodder, abs }

    /// The resulting (gpodder, abs) pair after `changed` was just set. Turning a
    /// source ON clears the other; turning it OFF leaves the other unchanged.
    static func resolved(gpodder: Bool, abs: Bool, changed: Source) -> (gpodder: Bool, abs: Bool) {
        switch changed {
        case .gpodder: return (gpodder, gpodder ? false : abs)
        case .abs:     return (abs ? false : gpodder, abs)
        }
    }
}
