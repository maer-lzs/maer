// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

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
    /// X²·1: which curated row an entry belongs to — explicit data instead of
    /// the old author/language heuristics.
    enum Group { case oerr, independent }

    /// X²·1: the FORM meta line of an independent tile — anthology (magazine
    /// collections), series (one continuing story) or reading (recited text).
    enum Form {
        case anthology, series, reading
        var label: String {
            switch self {
            case .anthology: String(localized: "Anthology")
            case .series: String(localized: "Serial")
            case .reading: String(localized: "Reading")
            }
        }
    }

    struct Entry: Identifiable {
        let title: String
        let author: String
        let feedURL: String
        /// 0ce5df3: language of the stock — an English entry only shows when
        /// English is among the suggestion languages (same rule as the
        /// Old-Time-Radio shelf). nil = German-language, always shown.
        var language: String? = nil
        var group: Group = .oerr
        /// X²·3: the country axis of the OERR sub-page (nil for independents).
        var country: OERRCuration.Country? = nil
        /// L1 (09.08.): artwork the DIRECTORY already delivered
        /// (`artworkUrl600`). The hand-curated seed leaves this nil — those
        /// entries resolve their picture from the feed itself. For entries
        /// found LIVE the picture was thrown away at the tile
        /// (`artworkURL: nil`), which is why the English tiles stayed grey
        /// although the source had a picture (BEFUND-G class).
        var artworkURL: String? = nil
        /// nil for OERR entries (their rights live with the broadcaster).
        var form: Form? = nil
        /// X²·1 (P6a-Geist): the CC capsule ONLY where the FEED itself states
        /// it (verified per feed, never blanket). Site-wide statements stay
        /// out until decided otherwise (report carries the evidence).
        var ccLicense: String? = nil
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
              feedURL: "https://www1.wdr.de/mediathek/audio/hoerspiel-speicher/wdr_hoerspielspeicher150.podcast",
              country: .germany),
        Entry(title: "Große Geschichten – ARD Literatur-Hörspiele", author: "BR",
              feedURL: "https://feeds.br.de/hoerspiel-pool/feed.xml", country: .germany),
        Entry(title: "hr2 Hörspiel", author: "hr",
              feedURL: "https://podcast.hr.de/hr2_hoerspiel/podcast.xml", country: .germany),
        Entry(title: "Ö1 Hörspiel und Radiokunst", author: "ORF",
              feedURL: "https://podcast.orf.at/podcast/oe1/oe1_hoerspiel/oe1_hoerspiel.xml",
              country: .austria),
        // Auftrag N2 (08.08.2026): the measured ÖRR sweep — Bestand vor
        // Neuzugängen, so the four familiar tiles above keep their spots.
        Entry(title: "SWR Kultur Hörspiel", author: "SWR",
              feedURL: "https://www.swr.de/~podcast/swrkultur/hoerspiel/podcast-hoerspiel-100.xml",
              country: .germany),
        Entry(title: "Hörspiele und Lesungen bei MDR KULTUR", author: "MDR",
              feedURL: "https://www.mdr.de/kultur/podcast/hoerspiele/audiogalerie-106.xml",
              country: .germany),
        Entry(title: "Freispiel – Hörspiel und Feature", author: "Deutschlandfunk Kultur",
              feedURL: "https://www.hoerspielundfeature.de/podcast-hoerspiel-100.xml",
              country: .germany),
        Entry(title: "SRF Hörspiel", author: "SRF",
              feedURL: "https://www.srf.ch/feed/podcast/sd/553f3450-1697-4fc5-ad79-0dead1605c8f.xml",
              country: .switzerland),
        Entry(title: "SRF Krimi", author: "SRF",
              feedURL: "https://www.srf.ch/feed/podcast/sd/5ba1cc91-64f2-4583-a72c-7d8194d7b163.xml",
              country: .switzerland),
        Entry(title: "Schreckmümpfeli", author: "SRF",
              feedURL: "https://www.srf.ch/feed/podcast/sd/46500e89-d57c-4684-aefb-2e5cb1adbca0.xml",
              country: .switzerland),
        // X²·1 (08.08., Fusion): ONE independent row — anthologies, series
        // and readings; the form is a data field, the meta line shows it.
        // Every entry live-verified (items count + enclosure spot check 200);
        // the eleven X²-candidates ALL passed (incl. Old Gods — the freemium
        // suspicion did not hold: full 27–63 min episodes in the open feed).
        // CC capsules only where the FEED states the licence (Penumbra CC BY
        // 3.0, SAYER CC BY 4.0); the Escape-Artists magazines state CC only
        // site-wide, so they carry none until decided (report).
        Entry(title: "Decoder Ring Theatre", author: "Gregg Taylor",
              feedURL: "https://decoderring.libsyn.com/rss", language: "en",
              group: .independent, form: .series),
        Entry(title: "PodCastle", author: "Escape Artists",
              // 09.08. GEMESSEN: der /podcast/-Pfad antwortet mit HTTP 200 und
              // einer WordPress-Fehlerseite (`<error>Database Error`), aus der
              // die App eine Show baute. Der Pfad ohne /podcast/ liefert
              // dieselbe Show mit Vollfolgen (PC 953-955, 5-100 MB, 40 Items).
              feedURL: "https://podcastle.org/feed/", language: "en",
              group: .independent, form: .anthology),
        Entry(title: "PseudoPod", author: "Escape Artists",
              feedURL: "https://pseudopod.org/feed/podcast/", language: "en",
              group: .independent, form: .anthology),
        Entry(title: "Radio Drama Revival", author: "Radio Drama Revival",
              feedURL: "https://feeds.captivate.fm/radio-drama-revival/", language: "en",
              group: .independent, form: .anthology),
        Entry(title: "The Truth", author: "The Truth",
              feedURL: "https://feeds.megaphone.fm/SBP9327453320", language: "en",
              group: .independent, form: .anthology),
        // 0bbdf3e rule: FIRST-PARTY addresses, never tracking wrappers.
        Entry(title: "Escape Pod", author: "Escape Artists",
              feedURL: "https://escapepod.org/feed/podcast/", language: "en",
              group: .independent, form: .anthology),
        // N1: full feed lives WITHOUT www (www serves a 10-item stub).
        Entry(title: "Cast of Wonders", author: "Escape Artists",
              feedURL: "https://castofwonders.org/feed/podcast/", language: "en",
              group: .independent, form: .anthology),
        // N4 (measured): the strongest independent serialized dramas.
        Entry(title: "Welcome to Night Vale", author: "Night Vale Presents",
              feedURL: "https://feeds.megaphone.fm/SBP4591212513", language: "en",
              group: .independent, form: .series),
        Entry(title: "The Bright Sessions", author: "Atypical Artists",
              feedURL: "https://rss.art19.com/the-bright-sessions", language: "en",
              group: .independent, form: .series),
        Entry(title: "Wolf 359", author: "Kinda Evil Genius Productions",
              feedURL: "https://feeds.megaphone.fm/wolf359radio", language: "en",
              group: .independent, form: .series),
        Entry(title: "ars PARADOXICA", author: "ars PARADOXICA",
              feedURL: "https://rss.libsyn.com/shows/108705/destinations/591779.xml", language: "en",
              group: .independent, form: .series),
        Entry(title: "We're Alive", author: "Wayland Productions",
              feedURL: "https://feeds.acast.com/public/shows/d1b39068-c10f-5817-8324-88ba173183cd", language: "en",
              group: .independent, form: .series),
        Entry(title: "The Magnus Archives", author: "Rusty Quill",
              feedURL: "https://feeds.acast.com/public/shows/b6085bcd-3542-4a43-b6a8-021e3fd251b8", language: "en",
              group: .independent, form: .series),
        Entry(title: "The White Vault", author: "Fool and Scholar Productions",
              feedURL: "https://feeds.megaphone.fm/SBP7754210900", language: "en",
              group: .independent, form: .series),
        // X²·1 enrichment (08.08., all measured):
        Entry(title: "The Drabblecast", author: "Norm Sherman",
              feedURL: "https://www.drabblecast.org/feed/podcast-m4a/", language: "en",
              group: .independent, form: .anthology),
        Entry(title: "StarShipSofa", author: "District of Wonders",
              feedURL: "https://feeds.acast.com/public/shows/9077c08c-f50e-4ce8-95d1-03fbe7cc72d1", language: "en",
              group: .independent, form: .anthology),
        Entry(title: "Tales to Terrify", author: "District of Wonders",
              feedURL: "https://feeds.acast.com/public/shows/9e301552-3a7e-439d-9125-3b646d65cffb", language: "en",
              group: .independent, form: .anthology),
        Entry(title: "Clarkesworld Magazine", author: "Clarkesworld",
              feedURL: "https://clarkesworldmagazine.com/?feed=podcast", language: "en",
              group: .independent, form: .anthology),
        Entry(title: "Lightspeed Magazine", author: "Adamant Press",
              feedURL: "https://feeds.megaphone.fm/SBP7078874085", language: "en",
              group: .independent, form: .anthology),
        Entry(title: "The Penumbra Podcast", author: "Sophie Takagi Kaner & Kevin Vibert",
              feedURL: "https://feeds.acast.com/public/shows/6831c608381499796b234652", language: "en",
              group: .independent, form: .series, ccLicense: "CC BY 3.0"),
        Entry(title: "Alice Isn't Dead", author: "Night Vale Presents",
              feedURL: "https://feeds.megaphone.fm/SBP8990444845", language: "en",
              group: .independent, form: .series),
        Entry(title: "King Falls AM", author: "King Falls AM",
              feedURL: "https://rss.libsyn.com/shows/474897/destinations/4028520.xml", language: "en",
              group: .independent, form: .series),
        Entry(title: "The Silt Verses", author: "Jon Ware & Muna Hussen",
              feedURL: "https://feeds.acast.com/public/shows/5fec690f8211cf453a1b89e2", language: "en",
              group: .independent, form: .series),
        Entry(title: "SAYER", author: "FK Creative Labs",
              feedURL: "https://feeds.feedburner.com/sayer", language: "en",
              group: .independent, form: .series, ccLicense: "CC BY 4.0"),
        Entry(title: "Old Gods of Appalachia", author: "DeepNerd Media",
              feedURL: "https://feeds.acast.com/public/shows/61ba0a431a8cbeb6ea3cf11a", language: "en",
              group: .independent, form: .series),
        // X²·2 (the owner entschieden): the German independents — community
        // honestly named (LibriVox principle); language nil = always visible,
        // so the row's language bracket fell (mixed preview by language).
        // hoer-talk-Vertiefung (08.08., gemessen): the ONE independent
        // German production feed the portal scene still hosts itself — 66
        // items, 43 of them full episodes (sample 70 MB audio/mpeg), running
        // (newest 2026-06-28). The identical file is served under
        // rick-future.de; `atom:link rel="self"` names THIS one as canonical,
        // so only one is curated. No CC anywhere on the site — the feed
        // carries a plain copyright, hence no licence capsule.
        Entry(title: "Rick Future", author: "Sven Matthias",
              feedURL: "https://www.hoer-talk.de/rfpodcast.xml",
              group: .independent, form: .series),
        Entry(title: "Das Hörspielprojekt", author: "Hörspielprojekt.de (Community)",
              feedURL: "https://hoerspielprojekt.de/hoerspiele.xml",
              group: .independent, form: .anthology),
        Entry(title: "texte von gestern", author: "Lauscherlounge",
              feedURL: "https://cdn.julephosting.de/podcasts/633-texte-von-gestern/feed.rss",
              group: .independent, form: .reading),
    ]
}