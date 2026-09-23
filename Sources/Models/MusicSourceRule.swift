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
    enum Server: Equatable, Sendable {
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
        if ItemNamespace.isJellyfin(itemId) { return .jellyfin }
        if ItemNamespace.isSubsonic(itemId) { return .subsonic }
        return device
    }
}
