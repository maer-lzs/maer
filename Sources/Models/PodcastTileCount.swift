// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation

/// The number on a show tile, app-wide. Decided: all unplayed episodes,
/// as Apple Podcasts and Pocket Casts count; the older rule "unplayed
/// and newer than the last one played" stays as the second choice, and
/// off is the third. One choice for every show; the per-show inbox mode
/// (all, latest, off) governs which new episodes reach the inbox and
/// notifications, not this number.
nonisolated enum PodcastTileCount: String, CaseIterable, Sendable {
    case allUnplayed
    case newSinceLastPlayed
    case off

    static let storageKey = "podcastTileCountMode"
    static let standard: PodcastTileCount = .allUnplayed

    /// The mode a stored raw value names; anything unknown is the standard.
    static func mode(raw: String?) -> PodcastTileCount {
        raw.flatMap(PodcastTileCount.init(rawValue:)) ?? standard
    }

    /// The number to show, or nil for no badge. `unplayed` counts every
    /// unplayed episode of the show, `newSinceLastPlayed` only those newer
    /// than the last one played; an episode in progress is in neither.
    func badge(unplayed: Int, newSinceLastPlayed: Int) -> Int? {
        let value: Int
        switch self {
        case .allUnplayed: value = unplayed
        case .newSinceLastPlayed: value = newSinceLastPlayed
        case .off: return nil
        }
        return value > 0 ? value : nil
    }
}
