// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation
import OSLog

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
    /// decision is legitimate, not a sacrifice. Two parts, decided wording:
    /// what stops, plus what the user KEEPS.
    let effectLine: String
    /// The keeps-part of the effect line, verbatim (the fence holds it
    /// against `effectLine`, so the two-part form cannot silently erode
    /// when the twelfth source arrives). Truth per source, measured, never
    /// the same sentence everywhere.
    let staysLine: String
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
        effectLine: String(localized: "The LibriVox rows then load nothing new; anything you started stays and keeps playing."),
        staysLine: String(localized: "anything you started stays and keeps playing"),
        hosts: ["librivox.org"],
        storageKey: "librivoxRowsEnabled")

    static let gutenberg = ExternalSource(
        key: "gutenberg", group: .catalogs,
        title: "Project Gutenberg",
        effectLine: String(localized: "The Gutenberg rows then load nothing new; anything you started stays and keeps playing."),
        staysLine: String(localized: "anything you started stays and keeps playing"),
        hosts: ["gutendex.com", "www.gutenberg.org"],
        storageKey: AppStorageKeys.gutenbergSourceEnabled)

    static let internetArchive = ExternalSource(
        key: "internetArchive", group: .catalogs,
        title: "Internet Archive",
        effectLine: String(localized: "Audiobooks, old-time radio, netlabels and 78s then load nothing new; anything you started stays and keeps playing."),
        staysLine: String(localized: "anything you started stays and keeps playing"),
        hosts: ["archive.org"],
        storageKey: "archivePopularEnabled")

    static let jamendo = ExternalSource(
        key: "jamendo", group: .catalogs,
        title: "Jamendo",
        effectLine: String(localized: "The free-music rows then load nothing new; anything you started stays and keeps playing."),
        staysLine: String(localized: "anything you started stays and keeps playing"),
        hosts: ["api.jamendo.com"],
        storageKey: "jamendoRowEnabled")

    static let podcastIndex = ExternalSource(
        key: "podcastIndex", group: .directories,
        title: "Podcast Index",
        effectLine: String(localized: "The podcast search then finds your own subscriptions. New feeds can still be added by hand."),
        staysLine: String(localized: "your own subscriptions"),
        hosts: ["api.podcastindex.org"],
        storageKey: AppStorageKeys.podcastIndexSourceEnabled)

    static let appleCatalog = ExternalSource(
        key: "appleCatalog", group: .directories,
        title: "Apple Podcasts",
        effectLine: String(localized: "Podcast charts and Apple search results then stay away. Your subscriptions are unaffected."),
        staysLine: String(localized: "Your subscriptions are unaffected."),
        hosts: ["itunes.apple.com"],
        storageKey: "appleCatalogEnabled")

    static let radioBrowser = ExternalSource(
        key: "radioBrowser", group: .directories,
        title: "Radio Browser",
        effectLine: String(localized: "Radio keeps your saved and recently played stations; new ones are no longer found through the catalog."),
        staysLine: String(localized: "Radio keeps your saved and recently played stations"),
        hosts: ["de1.api.radio-browser.info", "at1.api.radio-browser.info",
                "nl1.api.radio-browser.info", "all.api.radio-browser.info"],
        // The radio AREA switch was always the answer to exactly this
        // question (it gates the catalog fetches via SourceActivation), so
        // the source REUSES it. A fresh key would have meant two switches
        // for one service, one of them dead.
        storageKey: AppStorageKeys.radioEnabled)

    static let wikimedia = ExternalSource(
        key: "wikimedia", group: .enrichment,
        title: "Wikidata / Wikimedia Commons",
        effectLine: String(localized: "Tiles keep the logos they have; new stations get initials."),
        staysLine: String(localized: "Tiles keep the logos they have"),
        hosts: ["www.wikidata.org", "commons.wikimedia.org", "upload.wikimedia.org",
                "query.wikidata.org"],
        storageKey: "radioLogoChainEnabled")

    static let musicBrainz = ExternalSource(
        key: "musicBrainz", group: .enrichment,
        title: "MusicBrainz / Cover Art Archive",
        effectLine: String(localized: "Artists and albums keep the images they have; new ones stay without."),
        staysLine: String(localized: "Artists and albums keep the images they have"),
        hosts: ["musicbrainz.org", "coverartarchive.org"],
        storageKey: "musicArtistImagesOnline")

    static let lrclib = ExternalSource(
        key: "lrclib", group: .enrichment,
        title: "LRCLIB",
        // Measured (Lyrics.swift `gated`): off hides even already-fetched
        // web lyrics; lyrics the server carries keep showing.
        effectLine: String(localized: "Songs then play without lyrics from the web; even ones already fetched stop showing. Lyrics from your own server stay visible."),
        staysLine: String(localized: "Lyrics from your own server stay visible."),
        hosts: ["lrclib.net"],
        storageKey: "musicLyricsOnlineLookup")

    static let feedArtwork = ExternalSource(
        key: "feedArtwork", group: .enrichment,
        title: String(localized: "Covers from podcast hosts"),
        effectLine: String(localized: "Episode covers already loaded stay; new ones fall back to the show cover."),
        staysLine: String(localized: "Episode covers already loaded stay"),
        // Feed hosts are as many as there are podcasts. This source is the
        // PERMISSION to fetch artwork from wherever a feed points, so it
        // declares no fixed host list; the fence treats feed hosts as
        // belonging to it.
        hosts: [],
        storageKey: AppStorageKeys.feedArtworkSourceEnabled)

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

    /// The collective operation is an ACTION, never a state: it flips the
    /// per-source keys and means nothing afterwards. (The master was a
    /// STATE over them; that class is gone.)
    static func disableAll(defaults: UserDefaults = .standard) {
        for source in all {
            defaults.set(false, forKey: source.storageKey)
        }
    }

    /// Carries the old master's OFF into the per-source keys, once.
    ///
    /// The master used to override every catalog switch. The new reading
    /// ignores it, so WITHOUT this a user who had turned the master off
    /// would silently start asking foreign services again, the one thing
    /// the rebuild must never do. Master ON needs no migration at all: the
    /// per-source keys kept their names, so they simply keep meaning what
    /// they meant.
    static func migrateMasterIfNeeded(defaults: UserDefaults = .standard) {
        guard defaults.object(forKey: AppStorageKeys.sourcesTwoQuestionsMigrated) == nil else { return }
        if defaults.object(forKey: AppStorageKeys.freeCatalogsMasterEnabled) as? Bool == false {
            var translated: [String] = []
            for source in all where source.group == .catalogs {
                defaults.set(false, forKey: source.storageKey)
                translated.append(source.key)
            }
            // The one master-governed row whose content is FEEDS, not a
            // catalog source: its tiles fetch artwork from foreign hosts the
            // moment they render, and the old master's promise was "off
            // stops the traffic". Every other surface dies through its
            // sources; this one needs its row written off explicitly.
            defaults.set(false, forKey: AppStorageKeys.rowPodcastsRadioPlaysVisible)
            translated.append("row:podcasts.radioPlays")
            // The migration names what it changed. A one-time write that
            // reshapes stored choices without a trace would be undebuggable.
            Logger.library.notice("SOURCES migration: master OFF translated to \(translated.joined(separator: ","), privacy: .public)")
        }
        defaults.set(true, forKey: AppStorageKeys.sourcesTwoQuestionsMigrated)
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
