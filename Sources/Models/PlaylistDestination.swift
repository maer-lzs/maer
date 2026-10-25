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
    /// only when a server may take them (`servers`).
    static func places(servers: [MusicSourceRule.Server]) -> [PlaylistPlace] {
        servers.isEmpty ? [.device] : [.server, .device]
    }

    /// The music servers these entries may be filed on.
    /// A server playlist holds only its own server's titles: a catalogue
    /// track has no address on Navidrome, and a Jellyfin song none there
    /// either. So:
    /// - no entries yet (an empty new list): every active server, to choose;
    /// - entries of ONE active server: that server;
    /// - anything else (an entry no server holds, entries of two servers,
    ///   a server that is not active): none, the device list only.
    /// `owners` holds each entry's server by its namespace.
    static func servers(active: [MusicSourceRule.Server],
                        owners: [MusicSourceRule.Server?]) -> [MusicSourceRule.Server] {
        guard !owners.isEmpty else { return active }
        let held = owners.compactMap { $0 }
        guard held.count == owners.count, let first = held.first,
              held.allSatisfy({ $0 == first }), active.contains(first) else { return [] }
        return [first]
    }

    /// The server whose playlist changed last, for the preselection of an
    /// empty new list; nil when no list carries a moment.
    static func lastChanged(_ playlists: [(server: MusicSourceRule.Server, changedAt: Double?)]) -> MusicSourceRule.Server? {
        playlists.compactMap { entry in entry.changedAt.map { (entry.server, $0) } }
            .max { $0.1 < $1.1 }?.0
    }

    /// Entries of two servers at once: they fit a device list only, and
    /// the sheet says why instead of leaving the server section out silently.
    static func mixesServers(_ owners: [MusicSourceRule.Server?]) -> Bool {
        Set(owners.compactMap { $0 }).count > 1
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

/// The sentence under "Mär playlists" when the entries fit only there. It
/// names the server by its product, else "your music server"; with no music
/// server set up at all it names none, because there is none to blame.
nonisolated enum PlaylistOnlyMaerSentence {
    static func text(namedServer: String?, anyMusicServer: Bool) -> String {
        guard anyMusicServer else {
            return String(localized: "These entries only fit into a Mär playlist.")
        }
        if let name = namedServer {
            return String(localized: "These entries can only go into a Mär playlist: \(name) cannot reference a catalog or local address.")
        }
        return String(localized: "These entries can only go into a Mär playlist: your music server cannot reference a catalog or local address.")
    }
}

/// The footer of a Mär playlist's page. With a music server it says what
/// the lists mix and that they stay on the devices; with none set up it
/// names no server's music, only one the person may add.
nonisolated enum MaerPlaylistFooter {
    static func text(anyMusicServer: Bool) -> String {
        guard anyMusicServer else {
            return String(localized: "Playlists on your devices can mix everything: open catalogs, local files and music from a server you add.")
        }
        return String(localized: "Playlists on your devices mix music from your server, from open catalogs and your own files. They stay on your devices.")
    }
}
