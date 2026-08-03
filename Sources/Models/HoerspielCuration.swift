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
        var id: String { feedURL }
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
    ]
}
