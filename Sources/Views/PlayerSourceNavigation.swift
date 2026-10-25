// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import SwiftUI
import OSLog

/// Full player to source pages: the full player can navigate to the
/// running content's source page. Apple-Media convention. The player
/// MINIMIZES (never stops) and the target page is pushed on the library
/// stack in the matching tab, through the SAME value-based routes the
/// global search already uses. No second deep-link mechanism.
nonisolated enum PlayerSourceTarget {
    case book(itemId: String)
    /// A catalog audiobook: its one detail page, catalog entrance. A
    /// catalog work never stands in the library's entries, so `.book`
    /// would find nothing to show.
    case catalogBook(itemId: String)
    case podcastShow(feedURL: String)
    case podcastEpisode(itemId: String)
    case musicAlbum(LibraryItem)
    /// A free-catalogue item. Its page holds the tracks of the release.
    case catalogAlbum(itemId: String)
    case musicArtist(MusicArtist)
    /// The station detail page. Radio has a source target now.
    case radioStation(RadioStation)
    /// The list of latest episodes across shows. Where a message about
    /// SEVERAL shows leads. No single page can answer it, and this one was
    /// already there.
    case podcastLatest
}

extension PlayerSourceTarget {
    /// The tab a target lives in. It follows from the target, so it is
    /// decided here once instead of set by hand next to every push. No
    /// `default`: a new target does not compile until it names its tab.
    nonisolated var tab: MediaType {
        switch self {
        case .book, .catalogBook: .audiobooks
        case .podcastShow, .podcastEpisode, .podcastLatest: .podcasts
        case .musicAlbum, .musicArtist, .catalogAlbum: .music
        case .radioStation: .radio
        }
    }
}

/// Gate 2: the environment-based wiring was fragile. A mount
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

    /// Whether taps can navigate at all. The title renders PLAIN (no false
    /// affordance) while no handler is registered.
    var canRoute: Bool { handler != nil }

    func open(_ target: PlayerSourceTarget) {
        Logger.library.notice("PLAYERSOURCE route target=\(String(describing: target), privacy: .public) handler=\(self.handler != nil)")
        handler?(target)
    }
}

/// Pure target derivation from the playing item's namespaced id (tested):
/// which tap targets the full player offers. Radio targets the station
/// detail page.
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

    /// The page of a catalogue title by its form: a song opens its release,
    /// an album its album page, any reading (Gutenberg, LibriVox, a work of
    /// the archive) its book page. Never the album page for a reading.
    static func catalogPage(_ id: String, markedForm: ProgressMark.StartedForm?) -> PlayerSourceTarget {
        if CatalogSongID.isSong(id) { return .catalogAlbum(itemId: CatalogSongID.album(of: id)) }
        return MediaFamily.isMusicByForm(id, markedForm: markedForm) ? .catalogAlbum(itemId: id) : .catalogBook(itemId: id)
    }
}
