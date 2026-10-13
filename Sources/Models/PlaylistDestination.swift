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

/// The product name of a music server, for a sentence that names it
/// ("music from Navidrome"): Jellyfin by its provider, a Subsonic server by
/// the `type` its answers carry (OpenSubsonic; measured: a Navidrome sends
/// "navidrome" in every answer, an error without sign-in too; the other five
/// entries are not measured, and a wrong one only falls back to the sentence
/// without a name). A type this
/// list does not know, or none (plain Subsonic, older Airsonic), gives nil,
/// and the sentence says "your music server". Never the address.
nonisolated enum MusicServerName {
    static let known: [String: String] = [
        "navidrome": "Navidrome", "gonic": "gonic", "airsonic-advanced": "Airsonic-Advanced",
        "ampache": "Ampache", "funkwhale": "Funkwhale", "lms": "LMS",
    ]

    static func product(_ server: MusicSourceRule.Server?, reportedType: String?) -> String? {
        switch server {
        case .jellyfin: return "Jellyfin"
        case .subsonic: return reportedType.flatMap { known[$0.lowercased()] }
        case nil: return nil
        }
    }
}
