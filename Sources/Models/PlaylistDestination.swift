// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation

/// Where a playlist lives. The two worlds are not a preference but a
/// property of the data: a server playlist can only reference what the
/// server owns, a device list can hold every address this app knows.
nonisolated enum PlaylistPlace: String, CaseIterable, Identifiable, Sendable {
    case server, device
    var id: String { rawValue }
}

/// The two decisions behind the ONE create dialog and the ONE add sheet,
/// pure and testable: WHERE entries may go, and HOW one id
/// contributes its entries.
nonisolated enum PlaylistDestination {

    // MARK: - Where

    /// The places these entries may be filed in. The device place always
    /// stands. Every queueable address fits there. The server place stands
    /// only with a server behind it AND only for entries that server owns:
    /// a catalogue track has no address on Navidrome, so offering the
    /// section would be a dead target (G8).
    static func places(serverConfigured: Bool, allOwnedByServer: Bool) -> [PlaylistPlace] {
        (serverConfigured && allOwnedByServer) ? [.server, .device] : [.device]
    }

    // MARK: - How

    /// How one id contributes to a DEVICE list.
    enum Expansion: Equatable {
        /// One id, one entry. A song, an episode, a book, a work.
        case asIs
        /// A server container (album, playlist): the server states its songs.
        case serverContainer
        /// A catalogue release: the album/work switch decides, because a
        /// reading or radio play IS one entry while a record is its tracks.
        case catalogRelease
    }

    /// "Playlists are SONGS, not albums" holds in BOTH worlds. The first
    /// build asked this question only of catalogue ids, so a server album
    /// still went into a device list as a single entry. The same defect
    /// class, one namespace over. This is now the one place that answers it.
    ///
    /// `serverKind` is what the music provider says about the id (nil when it
    /// does not own it). The rule never parses provider prefixes itself.
    static func expansion(for itemId: String, serverKind: MusicItemKind?) -> Expansion {
        if let serverKind {
            switch serverKind {
            case .album, .playlist: return .serverContainer
            case .song, .artist:    return .asIs
            }
        }
        // A catalogue SONG address already names one track; a plain release
        // id means the whole thing and has to ask the form switch.
        if itemId.hasPrefix(FreeCatalog.archivePrefix), CatalogSongID.parse(itemId) == nil {
            return .catalogRelease
        }
        return .asIs
    }
}
