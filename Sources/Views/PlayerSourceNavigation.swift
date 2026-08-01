// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI
import OSLog

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
    /// V10: the station detail page — radio has a source target now.
    case radioStation(RadioStation)
}

/// Gate 2 (8913feb): the environment-based wiring was fragile — a mount
/// context without the env value made the tap a SILENT no-op (rule 3). This
/// router is the ONE central navigation point, independent of any
/// presentation context; LibraryView (the owner of the navigation path)
/// registers the handler once. Diagnosis logs stay in (log-first): the
/// device log shows immediately whether a tap fires and whether it routes.
@MainActor
final class PlayerSourceRouter {
    static let shared = PlayerSourceRouter()
    /// Registered by LibraryView; nil only before the library ever mounted.
    var handler: ((PlayerSourceTarget) -> Void)?

    /// Whether taps can navigate at all — the title renders PLAIN (no false
    /// affordance, G8 line) while no handler is registered.
    var canRoute: Bool { handler != nil }

    func open(_ target: PlayerSourceTarget) {
        Logger.library.notice("PLAYERSOURCE route target=\(String(describing: target), privacy: .public) handler=\(self.handler != nil)")
        handler?(target)
    }
}

/// Pure target derivation from the playing item's namespaced id (tested):
/// which tap targets the full player offers. V10: radio targets the station
/// detail page (no longer excluded).
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
    /// V10: radio ids (catalog AND manual) — the title taps to the detail.
    static func isRadio(_ id: String) -> Bool {
        id.hasPrefix("radio:")
    }
}
