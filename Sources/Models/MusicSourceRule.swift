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

    /// The device's music source. With both active, Subsonic wins for now
    /// (the product question of F5b decides what "both" means).
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
