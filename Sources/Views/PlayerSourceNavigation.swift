// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

/// Vollplayer → Quellseiten (9aad53c): the full player can navigate to the
/// running content's source page — Apple-Media convention. The player
/// MINIMIZES (never stops) and the target page is pushed on the library
/// stack in the matching tab, through the SAME value-based routes the
/// global search already uses (Regel 2 — no second deep-link mechanism).
nonisolated enum PlayerSourceTarget {
    case book(itemId: String)
    case podcastShow(feedURL: String)
    case podcastEpisode(itemId: String)
    case musicAlbum(LibraryItem)
    case musicArtist(MusicArtist)
}

nonisolated struct OpenPlayerSourceKey: EnvironmentKey {
    static let defaultValue: @MainActor (PlayerSourceTarget) -> Void = { _ in }
}

extension EnvironmentValues {
    var openPlayerSource: @MainActor (PlayerSourceTarget) -> Void {
        get { self[OpenPlayerSourceKey.self] }
        set { self[OpenPlayerSourceKey.self] = newValue }
    }
}

/// Pure target derivation from the playing item's namespaced id (tested):
/// which tap targets the full player offers. Radio is deliberately excluded
/// (no detail destination yet — V10 will bring one).
nonisolated enum PlayerSourceTargets {
    /// The PRIMARY tap target of the title/subtitle line per media kind:
    /// audiobook → book detail (title tap) · podcast → show page (subtitle
    /// tap) · music → album page (subtitle tap).
    static func isBook(_ id: String) -> Bool {
        !id.hasPrefix("rss:") && !id.hasPrefix("abspod:") && !id.hasPrefix("sub:")
            && !id.hasPrefix("jf:") && !id.hasPrefix("radio:")
    }
    static func isPodcast(_ id: String) -> Bool {
        id.hasPrefix("rss:") || id.hasPrefix("abspod:")
    }
    static func isMusic(_ id: String) -> Bool {
        id.hasPrefix("sub:") || id.hasPrefix("jf:")
    }
}
