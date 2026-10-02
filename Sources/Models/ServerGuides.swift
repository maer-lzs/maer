// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation

/// A self-hosted server Mär works with: what it does, what it needs, what
/// one enters in Mär for it, the project's OWN documentation and its source
/// code (project site or repository, never a blog, a forum or a mirror).
/// Shown in every state, also once a server is connected. Data, not prose
/// in views: a test checks every address (https, project hosts only, no
/// doubles), the link probe outside watches them move.
nonisolated struct ServerGuide: Equatable, Sendable, Identifiable {
    let name: String
    /// The area the server feeds; nil for the sync service, which feeds
    /// none and carries this device's state to the others.
    let area: SourceMapArea?
    /// What it does, one sentence as an English key the view localizes. No
    /// ranking, no "recommended".
    let oneLiner: String
    /// What one enters in Mär for it, measured at the sign-in form.
    let signIn: SignIn
    let docs: String
    let repo: String

    var id: String { (area?.rawValue ?? "sync") + ":" + name }
    var docsURL: URL? { URL(string: docs) }
    var repoURL: URL? { URL(string: repo) }

    /// The sign-in forms of Mär, each named by where it is and what it
    /// asks. Several servers share a form, so they share its sentence.
    enum SignIn: String, CaseIterable, Sendable {
        case audiobookshelf, audiobookshelfPodcasts, subsonic, booksonic, funkwhale, jellyfin, gpodder,
             pinchflat, maerSync

        var sentence: String {
            switch self {
            case .audiobookshelf:
                "In Mär: Audiobooks, Audiobookshelf server. The server address, then your user name and password or an API token."
            case .audiobookshelfPodcasts:
                "In Mär: the same sign-in as for audiobooks, then switch on Audiobookshelf podcasts under Podcasts."
            case .subsonic:
                "In Mär: Music, Music Server. The server address, your user name and your password."
            case .booksonic:
                "In Mär: Music, Music Server. The server address, your user name and your password, then switch on Audiobooks for this server."
            case .funkwhale:
                "In Mär: Music, Music Server. The server address, your user name and the Subsonic password you request in Funkwhale's settings."
            case .jellyfin:
                "In Mär: Music, Jellyfin Server. The server address, your user name and your password."
            case .gpodder:
                "In Mär: Podcasts, Podcast sources, gpodder Sync. The server address, your user name and your password."
            case .pinchflat:
                "In Mär: Podcasts, Podcast sources. The server address and the route token from Pinchflat's settings; user name and password only if your server asks for them."
            case .maerSync:
                "In Mär: Mär Sync, below the areas. The server address, your account and your password."
            }
        }
    }
}

nonisolated enum ServerGuides {
    /// Every host an address may point to. A positive list.
    static let projectHosts: Set<String> = [
        "audiobookshelf.org", "www.audiobookshelf.org", "booksonic.org", "www.navidrome.org", "jellyfin.org",
        "github.com", "docs.funkwhale.audio", "dev.funkwhale.audio", "codeberg.org"
    ]

    /// What every server needs, one sentence for all: the projects' own
    /// guides name the rest, and a sentence per server here would age with
    /// each of their releases.
    static let needs = "A computer that stays on and that this device can reach, such as a NAS or a small home server. The project's documentation names what else it needs."

    /// The Works-with matrix is the measure: what is not verified or
    /// protocol-probed there is not here either.
    static let all: [ServerGuide] = [
        ServerGuide(name: "Audiobookshelf", area: .audiobooks,
                    oneLiner: "Audiobook and podcast server that keeps your listening progress.",
                    signIn: .audiobookshelf,
                    docs: "https://audiobookshelf.org/docs/category/installation/",
                    repo: "https://github.com/advplyr/audiobookshelf"),
        ServerGuide(name: "Booksonic", area: .audiobooks,
                    oneLiner: "Audiobook server that speaks the Subsonic API.",
                    signIn: .booksonic,
                    docs: "https://booksonic.org/download",
                    repo: "https://github.com/popeen/Booksonic-Air"),
        ServerGuide(name: "Navidrome", area: .music,
                    oneLiner: "Music server with the Subsonic API.",
                    signIn: .subsonic,
                    docs: "https://www.navidrome.org/docs/installation/",
                    repo: "https://github.com/navidrome/navidrome"),
        ServerGuide(name: "Jellyfin", area: .music,
                    oneLiner: "Media server with a music library.",
                    signIn: .jellyfin,
                    docs: "https://jellyfin.org/docs/general/installation/",
                    repo: "https://github.com/jellyfin/jellyfin"),
        ServerGuide(name: "gonic", area: .music,
                    oneLiner: "Small music server with the Subsonic API.",
                    signIn: .subsonic,
                    docs: "https://github.com/sentriz/gonic/wiki",
                    repo: "https://github.com/sentriz/gonic"),
        ServerGuide(name: "Airsonic Advanced", area: .music,
                    oneLiner: "Music server with the Subsonic API, maintained fork.",
                    signIn: .subsonic,
                    docs: "https://github.com/kagemomiji/airsonic-advanced/wiki",
                    repo: "https://github.com/kagemomiji/airsonic-advanced"),
        ServerGuide(name: "Funkwhale", area: .music,
                    oneLiner: "Federated music server with a Subsonic API.",
                    signIn: .funkwhale,
                    docs: "https://docs.funkwhale.audio/administrator/installation/index.html",
                    repo: "https://dev.funkwhale.audio/funkwhale/funkwhale"),
        ServerGuide(name: "oPodSync", area: .podcasts,
                    oneLiner: "Small gpodder server that keeps subscriptions in sync between devices.",
                    signIn: .gpodder,
                    docs: "https://github.com/kd2org/opodsync#readme",
                    repo: "https://github.com/kd2org/opodsync"),
        ServerGuide(name: "Pinchflat", area: .podcasts,
                    oneLiner: "Turns YouTube channels into podcast feeds.",
                    signIn: .pinchflat,
                    docs: "https://github.com/kieraneglin/pinchflat/wiki",
                    repo: "https://github.com/kieraneglin/pinchflat"),
        ServerGuide(name: "Audiobookshelf", area: .podcasts,
                    oneLiner: "Keeps podcasts and their progress on your own server.",
                    signIn: .audiobookshelfPodcasts,
                    docs: "https://audiobookshelf.org/docs/category/installation/",
                    repo: "https://github.com/advplyr/audiobookshelf"),
        ServerGuide(name: "Mär Sync", area: nil,
                    oneLiner: "Your own sync service: keeps progress, subscriptions, playlists, settings and statistics in step between your devices, without iCloud.",
                    signIn: .maerSync,
                    docs: "https://codeberg.org/LzS/maer-sync#readme",
                    repo: "https://codeberg.org/LzS/maer-sync"),
    ]

    static func guides(for area: SourceMapArea) -> [ServerGuide] {
        all.filter { $0.area == area }
    }

    /// What a list shows: one area's servers, or with no area every server
    /// once by name (Audiobookshelf serves two areas and stands under its
    /// first).
    static func listed(in area: SourceMapArea?) -> [ServerGuide] {
        if let area { return guides(for: area) }
        var seen = Set<String>()
        return all.filter { seen.insert($0.name).inserted }
    }

    /// Every text a guide page looks up at runtime, for the catalog.
    static var localizedKeys: [String] {
        all.map(\.oneLiner) + ServerGuide.SignIn.allCases.map(\.sentence) + [needs]
    }
}
