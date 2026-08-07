// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// e4bd910/hoerspiele: the curated public-broadcast radio-play entry —
/// PLAIN podcast feeds on home turf (no gray-API client, no new provider).
/// Pure DATA, extendable; every URL was LIVE-verified at build time
/// (03.08.2026 first round; 08.08.2026 Auftrag-N sweep — alive + delivering
/// episodes, enclosure spot checks 200). The old "Audiothek-only" note is
/// PARTLY outdated: SWR Kultur and Dlf (Freispiel) DO run open feeds now and
/// joined below; still without an open core radio-play feed: NDR (Hörspiel
/// Box confirmed Audiothek-only again), rbb and SR (nothing core). Kids
/// feeds (Kakadu, Figarino, SRF Kids, Ohrenbär) stay out deliberately — the
/// curation is adult radio drama.
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
        // Auftrag N2 (08.08.2026): the measured ÖRR sweep — Bestand vor
        // Neuzugängen, so the four familiar tiles above keep their spots.
        Entry(title: "SWR Kultur Hörspiel", author: "SWR",
              feedURL: "https://www.swr.de/~podcast/swrkultur/hoerspiel/podcast-hoerspiel-100.xml"),
        Entry(title: "Hörspiele und Lesungen bei MDR KULTUR", author: "MDR",
              feedURL: "https://www.mdr.de/kultur/podcast/hoerspiele/audiogalerie-106.xml"),
        Entry(title: "Freispiel – Hörspiel und Feature", author: "Deutschlandfunk Kultur",
              feedURL: "https://www.hoerspielundfeature.de/podcast-hoerspiel-100.xml"),
        Entry(title: "SRF Hörspiel", author: "SRF",
              feedURL: "https://www.srf.ch/feed/podcast/sd/553f3450-1697-4fc5-ad79-0dead1605c8f.xml"),
        Entry(title: "SRF Krimi", author: "SRF",
              feedURL: "https://www.srf.ch/feed/podcast/sd/5ba1cc91-64f2-4583-a72c-7d8194d7b163.xml"),
        Entry(title: "Schreckmümpfeli", author: "SRF",
              feedURL: "https://www.srf.ch/feed/podcast/sd/46500e89-d57c-4684-aefb-2e5cb1adbca0.xml"),
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
        // 0bbdf3e: Escape Pod was left out in the first round because the
        // Apple entry pointed at a measurement redirect (rss.pdrl.fm/…), not
        // the publisher's own address. the reviewer measured the original (300
        // episodes) — the rule stands: take the FIRST-PARTY address, never a
        // tracking wrapper, so the enclosures stay the publisher's.
        Entry(title: "Escape Pod", author: "Escape Artists",
              feedURL: "https://escapepod.org/feed/podcast/", language: "en"),
        // Auftrag N1 (08.08.2026): the fourth Escape-Artists magazine. NOTE
        // the address: the full feed (300 episodes, MP3 enclosures 200) lives
        // WITHOUT www — www.castofwonders.org serves a 10-item stub.
        Entry(title: "Cast of Wonders", author: "Escape Artists",
              feedURL: "https://castofwonders.org/feed/podcast/", language: "en"),
    ]
}
