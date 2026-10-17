// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation

// The two core podcast domain types. They are plain Codables and need
// nothing but Foundation; they lived in PodcastSubscriptions.swift,
// which imports Combine, and that address alone made them unreachable
// for the pure layer (the source watch compiles our real decoder on
// Linux, Foundation-only, and refused the file). Nothing about the
// types changed here, only where they live.
//
// The rule this file stands for: a domain type belongs where its
// PURITY is visible, never in whatever file happened to declare it
// first.

/// A subscribed show with its episodes (persisted so the latest episodes stay
/// visible offline). New metadata fields are optional (`= nil`) so existing
/// saved feeds decode unchanged.
nonisolated struct PodcastShow: Codable, Identifiable, Equatable {
    var id: String                 // stable feed id (derived from the URL)
    var title: String
    var author: String?
    var artworkURL: String?
    var description: String?
    var feedURL: String
    var episodes: [PodcastEpisode]
    // Rich metadata (RSS/Podcasting 2.0)
    var categories: [String]? = nil
    var link: String? = nil        // Website
    var language: String? = nil
    var explicit: Bool? = nil
    var funding: [PodcastFunding]? = nil
    var owner: String? = nil
    /// Provenance. Which server MIRRORS this feed
    /// (PinchflatMirror.originTag). nil = an ordinary subscription. Origin is
    /// a fact on the feed, not a second ordering tree.
    var origin: String? = nil
    var showType: String? = nil    // episodic | serial
}

nonisolated struct PodcastEpisode: Codable, Identifiable, Equatable {
    var guid: String
    var title: String
    var audioURL: String
    var pubDate: Double             // ms epoch
    var duration: Double            // seconds (0 if unknown) — FEED-Tatsache
    /// The length MEASURED from the asset. It is a STORE fact: a fresh parse
    /// cannot know it, because it only comes into existence during playback.
    /// Hence its own field. While it merely overwrote `duration` it was
    /// indistinguishable from the feed's claim and died on every refresh.
    /// `duration` still mirrors it so every reader sees the best known length.
    var measuredDuration: Double? = nil
    /// The shownotes as the feed carries them. In the subscribed stock
    /// always nil: the notes live in the database and are read when the
    /// episode is opened (`PodcastNotes`); a parse and a browsed show
    /// carry them.
    var description: String?
    /// A stamp of the shownotes this episode's notes were written with
    /// (`PodcastNotes.stamp`), so an unchanged text is not written again.
    var notesStamp: Int? = nil
    var imageURL: String?
    /// Podcasting 2.0 chapters (`<podcast:chapters url=… type=json+chapters>`).
    /// Loaded only when opening the episode (RSSProvider.fetchItemDetail).
    var chaptersURL: String?
    // Rich metadata (optional → backward-compatible)
    var season: Int? = nil
    var episodeNumber: Int? = nil
    var episodeType: String? = nil // full | trailer | bonus
    var explicit: Bool? = nil
    var link: String? = nil
    var transcriptURL: String? = nil
    var persons: [PodcastPerson]? = nil

    var id: String { guid }

    /// An item without an audio enclosure is KEPT as a text-only
    /// episode. Visible (dimmed, show notes on tap) but never playable,
    /// queueable, downloadable or markable as played.
    var isPlayable: Bool { !audioURL.isEmpty }
}

/// Person from the feed (`<podcast:person>` / `itunes:owner`). Host/guest.
nonisolated struct PodcastPerson: Codable, Hashable {
    var name: String
    var role: String?
    var img: String?
    var href: String?
}

/// Support link of the show (`<podcast:funding>`).
nonisolated struct PodcastFunding: Codable, Hashable {
    var url: String
    var label: String?
}
