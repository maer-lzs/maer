// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation

/// A self-hosted server Mär works with: one sentence of what it is, and the
/// project's OWN installation guide (project site or repository, never a
/// blog, a forum or a mirror). Shown where an area still needs a server.
/// Data, not prose in views: a test checks every address (https, project
/// hosts only, no doubles), the link probe outside watches them move.
nonisolated struct ServerGuide: Equatable, Sendable, Identifiable {
    let name: String
    let area: SourceMapArea
    /// One sentence, as an English key the view localizes. No ranking, no
    /// "recommended".
    let oneLiner: String
    let docs: String

    var id: String { area.rawValue + ":" + name }
    var docsURL: URL? { URL(string: docs) }
}

nonisolated enum ServerGuides {
    /// Every host an address may point to. A positive list.
    static let projectHosts: Set<String> = [
        "www.audiobookshelf.org", "booksonic.org", "www.navidrome.org", "jellyfin.org",
        "github.com", "docs.funkwhale.audio"
    ]

    /// The Works-with matrix is the measure: what is not verified or
    /// protocol-probed there is not here either.
    static let all: [ServerGuide] = [
        ServerGuide(name: "Audiobookshelf", area: .audiobooks,
                    oneLiner: "Audiobook and podcast server that keeps your listening progress.",
                    docs: "https://www.audiobookshelf.org/docs/category/installation"),
        ServerGuide(name: "Booksonic", area: .audiobooks,
                    oneLiner: "Audiobook server that speaks the Subsonic API.",
                    docs: "https://booksonic.org/download"),
        ServerGuide(name: "Navidrome", area: .music,
                    oneLiner: "Music server with the Subsonic API.",
                    docs: "https://www.navidrome.org/docs/installation/"),
        ServerGuide(name: "Jellyfin", area: .music,
                    oneLiner: "Media server with a music library.",
                    docs: "https://jellyfin.org/docs/general/installation/"),
        ServerGuide(name: "gonic", area: .music,
                    oneLiner: "Small music server with the Subsonic API.",
                    docs: "https://github.com/sentriz/gonic"),
        ServerGuide(name: "Airsonic Advanced", area: .music,
                    oneLiner: "Music server with the Subsonic API, maintained fork.",
                    docs: "https://github.com/kagemomiji/airsonic-advanced"),
        ServerGuide(name: "Funkwhale", area: .music,
                    oneLiner: "Federated music server with a Subsonic API.",
                    docs: "https://docs.funkwhale.audio/administrator/installation/index.html"),
        ServerGuide(name: "oPodSync", area: .podcasts,
                    oneLiner: "Small gpodder server that keeps subscriptions in sync between devices.",
                    docs: "https://github.com/bohwaz/opodsync"),
        ServerGuide(name: "Pinchflat", area: .podcasts,
                    oneLiner: "Turns YouTube channels into podcast feeds.",
                    docs: "https://github.com/kieraneglin/pinchflat"),
        ServerGuide(name: "Audiobookshelf", area: .podcasts,
                    oneLiner: "Keeps podcasts and their progress on your own server.",
                    docs: "https://www.audiobookshelf.org/docs/category/installation"),
    ]

    static func guides(for area: SourceMapArea) -> [ServerGuide] {
        all.filter { $0.area == area }
    }

    /// Whether the area's page shows the guides: only while the area has
    /// no server of the user's own (the state decides, not a switch).
    static func showsGuides(for area: SourceMapArea, state: SourceMapState) -> Bool {
        switch state {
        case .needsServer: return true
        case .ready: return area == .podcasts
        case .connected, .readySynced: return false
        }
    }
}
