// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation

/// Grouped by what the LISTENER loses without them, not by vendor. The
/// sources page is a privacy page: it answers "whom may this app ask",
/// and the group answers "and what do I get for it".
nonisolated enum ExternalSourceGroup: String, CaseIterable, Sendable {
    /// Deliver something listenable.
    case catalogs
    /// Help finding things; nothing listenable comes from them.
    case directories
    /// Only trimmings: images, logos, lyrics.
    case enrichment
}

/// ONE foreign service the app may contact. The user's own servers (ABS,
/// Subsonic, Jellyfin, gpodder, Pinchflat) are deliberately NOT in this
/// list: they are the user's infrastructure, not a foreign source.
nonisolated struct ExternalSource: Identifiable, Sendable {
    /// Stable key. Also the anchor for the rows relation.
    let key: String
    let group: ExternalSourceGroup
    let title: String
    /// What HOLDS after switching it off. Descriptive, never warning: the
    /// decision is legitimate, not a sacrifice. Wording is proposed here;
    /// the final texts are a product decision.
    let effectLine: String
    /// The hosts this source is contacted under. The completeness fence
    /// holds them against the code's own host scan: a client talking to a
    /// host no source declares means this page has become a lie.
    let hosts: [String]
    /// The EXISTING defaults key where one exists, so no user's stored
    /// choice is reset by a rename. Sources that never had a switch get a
    /// new key.
    let storageKey: String

    var id: String { key }
}

/// The catalogue of foreign sources, as data. Grown from the measured host
/// scan of 30.08.; the fence keeps it honest from here on.
nonisolated enum ExternalSources {
    static let librivox = ExternalSource(
        key: "librivox", group: .catalogs,
        title: "LibriVox",
        effectLine: String(localized: "The LibriVox rows then show nothing new. Anything you started stays in your library."),
        hosts: ["librivox.org"],
        storageKey: "librivoxRowsEnabled")

    static let gutenberg = ExternalSource(
        key: "gutenberg", group: .catalogs,
        title: "Project Gutenberg",
        effectLine: String(localized: "The Gutenberg rows then show nothing new. Anything you started stays in your library."),
        hosts: ["gutendex.com", "www.gutenberg.org"],
        storageKey: "gutenbergSourceEnabled")

    static let internetArchive = ExternalSource(
        key: "internetArchive", group: .catalogs,
        title: "Internet Archive",
        effectLine: String(localized: "Audiobooks, old-time radio, netlabels and 78s then show nothing new. Anything you started stays in your library."),
        hosts: ["archive.org"],
        storageKey: "archivePopularEnabled")

    static let jamendo = ExternalSource(
        key: "jamendo", group: .catalogs,
        title: "Jamendo",
        effectLine: String(localized: "The free-music rows then show nothing new. Anything you started stays in your library."),
        hosts: ["api.jamendo.com"],
        storageKey: "jamendoRowEnabled")

    static let podcastIndex = ExternalSource(
        key: "podcastIndex", group: .directories,
        title: "Podcast Index",
        effectLine: String(localized: "The podcast search then finds your own subscriptions. New feeds can still be added by hand."),
        hosts: ["api.podcastindex.org"],
        storageKey: "podcastIndexSourceEnabled")

    static let appleCatalog = ExternalSource(
        key: "appleCatalog", group: .directories,
        title: "Apple Podcasts",
        effectLine: String(localized: "Podcast charts and Apple search results then stay away. Your subscriptions are unaffected."),
        hosts: ["itunes.apple.com"],
        storageKey: "appleCatalogEnabled")

    static let radioBrowser = ExternalSource(
        key: "radioBrowser", group: .directories,
        title: "Radio Browser",
        effectLine: String(localized: "Radio keeps your saved and recently played stations; new ones are no longer found through the catalog."),
        hosts: ["de1.api.radio-browser.info", "at1.api.radio-browser.info",
                "nl1.api.radio-browser.info", "all.api.radio-browser.info"],
        storageKey: "radioBrowserSourceEnabled")

    static let wikimedia = ExternalSource(
        key: "wikimedia", group: .enrichment,
        title: "Wikidata / Wikimedia Commons",
        effectLine: String(localized: "Tiles keep the logos they have; new stations get initials."),
        hosts: ["www.wikidata.org", "commons.wikimedia.org", "upload.wikimedia.org",
                "query.wikidata.org"],
        storageKey: "radioLogoChainEnabled")

    static let musicBrainz = ExternalSource(
        key: "musicBrainz", group: .enrichment,
        title: "MusicBrainz / Cover Art Archive",
        effectLine: String(localized: "Artists and albums keep the images they have; new ones stay without."),
        hosts: ["musicbrainz.org", "coverartarchive.org"],
        storageKey: "musicArtistImagesOnline")

    static let lrclib = ExternalSource(
        key: "lrclib", group: .enrichment,
        title: "LRCLIB",
        effectLine: String(localized: "Songs then play without lyrics."),
        hosts: ["lrclib.net"],
        storageKey: "musicLyricsOnlineLookup")

    static let feedArtwork = ExternalSource(
        key: "feedArtwork", group: .enrichment,
        title: String(localized: "Covers from podcast hosts"),
        effectLine: String(localized: "Episode covers already loaded stay; new ones fall back to the show cover."),
        // Feed hosts are as many as there are podcasts. This source is the
        // PERMISSION to fetch artwork from wherever a feed points, so it
        // declares no fixed host list; the fence treats feed hosts as
        // belonging to it.
        hosts: [],
        storageKey: "feedArtworkSourceEnabled")

    /// Every source, in the order the page shows them: by group, and
    /// inside a group by weight of what one loses.
    static let all: [ExternalSource] = [
        librivox, gutenberg, internetArchive, jamendo,
        podcastIndex, appleCatalog, radioBrowser,
        wikimedia, musicBrainz, lrclib, feedArtwork,
    ]

    static func source(key: String) -> ExternalSource? {
        all.first { $0.key == key }
    }

    /// Is this source allowed to be asked? ONE question, two states. The
    /// third, overriding level (the master) is what produced switches that
    /// said "on" and did nothing.
    static func isAllowed(_ source: ExternalSource,
                          defaults: UserDefaults = .standard) -> Bool {
        // Through the ONE default-reading place. A literal fallback here is
        // exactly the scattered-defaults class its fence guards against,
        // and the fence caught this line on its first run.
        AppStorageKeys.boolValue(source.storageKey, in: defaults)
    }
}
