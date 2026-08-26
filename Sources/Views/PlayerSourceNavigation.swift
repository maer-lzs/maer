// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import SwiftUI
import OSLog

/// Vollplayer → Quellseiten: the full player can navigate to the
/// running content's source page — Apple-Media convention. The player
/// MINIMIZES (never stops) and the target page is pushed on the library
/// stack in the matching tab, through the SAME value-based routes the
/// global search already uses — no second deep-link mechanism.
nonisolated enum PlayerSourceTarget {
    case book(itemId: String)
    case podcastShow(feedURL: String)
    case podcastEpisode(itemId: String)
    case musicAlbum(LibraryItem)
    /// A free-catalogue item — its page holds the tracks of the release.
    case catalogAlbum(itemId: String)
    case musicArtist(MusicArtist)
    /// The station detail page — radio has a source target now.
    case radioStation(RadioStation)
    /// The list of latest episodes across shows — where a message about
    /// SEVERAL shows leads. No single page can answer it, and this one was
    /// already there.
    case podcastLatest
}

/// Gate 2: the environment-based wiring was fragile — a mount
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
    /// All four ask `MediaFamily`, which defines every case positively. The
    /// book test used to be the leftover, so a catalogue id counted as a book
    /// and the title tap opened an empty audiobook page.
    static func isBook(_ id: String) -> Bool { MediaFamily.of(id) == .book }
    static func isPodcast(_ id: String) -> Bool { MediaFamily.of(id) == .podcast }
    static func isMusic(_ id: String) -> Bool { MediaFamily.of(id) == .music }
    static func isRadio(_ id: String) -> Bool { MediaFamily.of(id) == .radio }
    /// Free catalogues resolve to their catalogue page, not to a library tab.
    static func isCatalog(_ id: String) -> Bool { MediaFamily.of(id) == .catalog }
}
