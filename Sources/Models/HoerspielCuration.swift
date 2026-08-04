// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// e4bd910/hoerspiele: the curated public-broadcast radio-play entry —
/// PLAIN podcast feeds on home turf (no gray-API client, no new provider).
/// Pure DATA, extendable; every URL was LIVE-verified at build time
/// (03.08.2026, alive + delivering episodes). Dead candidates named in the
/// report instead of shipped: NDR Hörspiel Box, the SWR pool and the
/// Dlf/Dlf-Kultur pool are Audiothek-only today (no public RSS).
nonisolated enum HoerspielCuration {
    struct Entry: Identifiable {
        let title: String
        let author: String
        let feedURL: String
        /// 0ce5df3: language of the stock — an English entry only shows when
        /// English is among the suggestion languages (same rule as the
        /// Old-Time-Radio shelf). nil = German-language, always shown.
        var language: String? = nil
        var id: String { feedURL }
    }

    /// The entries that fit the user's suggestion languages.
    static func feeds(forLanguages codes: [String]) -> [Entry] {
        feeds.filter { entry in
            guard let language = entry.language else { return true }
            return codes.contains(language)
        }
    }

    static let feeds: [Entry] = [
        Entry(title: "ARD Hörspiel (WDR Hörspiel-Speicher)", author: "WDR",
              feedURL: "https://www1.wdr.de/mediathek/audio/hoerspiel-speicher/wdr_hoerspielspeicher150.podcast"),
        Entry(title: "Große Geschichten – ARD Literatur-Hörspiele", author: "BR",
              feedURL: "https://feeds.br.de/hoerspiel-pool/feed.xml"),
        Entry(title: "hr2 Hörspiel", author: "hr",
              feedURL: "https://podcast.hr.de/hr2_hoerspiel/podcast.xml"),
        Entry(title: "Ö1 Hörspiel und Radiokunst", author: "ORF",
              feedURL: "https://podcast.orf.at/podcast/oe1/oe1_hoerspiel/oe1_hoerspiel.xml"),
        // 0ce5df3: the living US audio-drama scene. Charts show mainstream
        // (incl. true crime); these are the productions that actually carry
        // the genre. Each verified live at build time (05.08.2026: alive,
        // episodes with enclosures, channel cover) — the same discipline as
        // the first round. English stock, so the page only shows them when
        // English is among the suggestion languages.
        Entry(title: "Decoder Ring Theatre", author: "Gregg Taylor",
              feedURL: "https://decoderring.libsyn.com/rss", language: "en"),
        Entry(title: "PodCastle", author: "Escape Artists",
              feedURL: "https://podcastle.org/feed/podcast/", language: "en"),
        Entry(title: "PseudoPod", author: "Escape Artists",
              feedURL: "https://pseudopod.org/feed/podcast/", language: "en"),
        Entry(title: "Radio Drama Revival", author: "Radio Drama Revival",
              feedURL: "https://feeds.captivate.fm/radio-drama-revival/", language: "en"),
        Entry(title: "The Truth", author: "The Truth",
              feedURL: "https://feeds.megaphone.fm/SBP9327453320", language: "en"),
    ]
}
