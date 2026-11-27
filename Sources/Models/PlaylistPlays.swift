// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation

/// When a playlist was last heard on this device, by its id: the moment
/// "Listen Again" ranks an own list by, and the one a server playlist
/// shuffled from its card leaves (an opened one has its stand). Only the
/// newest `keep` are held. It stays on the device.
nonisolated enum PlaylistPlays {
    static let keep = 50

    /// The moments with `id` heard at `atMs`, the newest `keep` of them.
    static func noting(_ id: String, atMs: Double, in moments: [String: Double]) -> [String: Double] {
        moments
    }

    /// The stored value as moments. A form this build does not know, or a
    /// broken one, reads as none.
    static func decoded(_ raw: Any?) -> [String: Double] {
        [:]
    }
}

/// The device's moments (`AppStorageKeys.playlistPlays`).
@MainActor
enum PlaylistPlaysStore {
    static func moments(defaults: UserDefaults = .standard) -> [String: Double] {
        PlaylistPlays.decoded(defaults.object(forKey: AppStorageKeys.playlistPlays))
    }

    static func note(_ id: String, atMs: Double = Date().timeIntervalSince1970 * 1000,
                     defaults: UserDefaults = .standard) {
    }
}
