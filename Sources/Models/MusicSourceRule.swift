// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation

/// Which music server answers, as a pure rule: for the DEVICE (a library
/// listing) and for one ITEM (a title that carries its source in its id).
/// `AppSession` asks here for both, so the two answers cannot drift apart:
/// with ONE active music source they are the same server by construction,
/// and only with two does the item's own server win over the device's.
nonisolated enum MusicSourceRule {
    enum Server: Hashable, Sendable {
        case subsonic
        case jellyfin
    }

    /// Who serves the music LISTS: one server, or both at once (decided:
    /// both music servers appear on every music surface together).
    enum Serving: Equatable, Sendable {
        case one(Server)
        case both
    }

    static func serving(subsonicServesMusic: Bool, jellyfinServesMusic: Bool) -> Serving {
        subsonicServesMusic && jellyfinServesMusic
            ? .both
            : .one(device(subsonicServesMusic: subsonicServesMusic, jellyfinServesMusic: jellyfinServesMusic))
    }

    /// The server an id WITHOUT a music namespace goes to. With both
    /// active that is Subsonic, as before the union: such ids are seeds and
    /// playlist ids built on this device.
    static func device(subsonicServesMusic: Bool, jellyfinServesMusic: Bool) -> Server {
        jellyfinServesMusic && !subsonicServesMusic ? .jellyfin : .subsonic
    }

    /// The server of one item: its namespace when it has one, else the
    /// device's source.
    static func item(_ itemId: String, device: Server) -> Server {
        owner(itemId) ?? device
    }

    /// The server an id belongs to by its namespace alone; nil for an id
    /// no music server holds (catalogue, local, episode).
    static func owner(_ itemId: String) -> Server? {
        if ItemNamespace.isJellyfin(itemId) { return .jellyfin }
        if ItemNamespace.isSubsonic(itemId) { return .subsonic }
        return nil
    }

    /// Whether an id is MUSIC of a music server, the question the player's
    /// music tools ask (lyrics, the song title, chapters as tracks). A music
    /// server's namespace, minus the Jellyfin audiobook that shares it. The
    /// tools used to ask `isSubsonic`, so a Jellyfin song had no lyrics and
    /// no song title.
    static func isServerMusic(_ itemId: String) -> Bool {
        guard owner(itemId) != nil else { return false }
        return JellyfinProvider.id(itemId, kind: "book") == nil
    }

    /// The music servers that serve music now, Subsonic first.
    static func active(subsonicServesMusic: Bool, jellyfinServesMusic: Bool) -> [Server] {
        (subsonicServesMusic ? [.subsonic] : []) + (jellyfinServesMusic ? [.jellyfin] : [])
    }
}
