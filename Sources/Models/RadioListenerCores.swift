// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation

/// 19a8b4c: first-hand listener-ranking CORES for the DACH discovery rows —
/// the "Beliebt in …" and region rows rank by what the audience measurably
/// listens to, not by Radio-Browser community votes (which vote like webradio
/// enthusiasts, not like the public). Names in PUBLISHED rank order; the rank
/// IS the array position. Pure data: names + order are facts from openly
/// published rankings — no database extract, no listener figures, no frozen
/// derived values (the cb8bac1 lesson). Station names resolve against the
/// live Radio-Browser catalog at row build; what doesn't resolve (marketer
/// entries like "RADIO NRW", combination packages) drops out honestly and is
/// logged. Semi-annual maintenance = replace a table with the next round's
/// names.
nonisolated enum RadioListenerCores {
    /// The ONE visible priority mapping (72d233f (4)):
    /// first-hand survey > Wikidata core > votes pure.
    static func national(countryCode: String?) -> [String]? {
        switch countryCode?.uppercased() {
        case "DE": return germanyNational
        case "AT": return austriaNational
        case "CH": return switzerlandNational
        default: return RadioWikidataCores.national(countryCode: countryCode)
        }
    }

    /// Regional core for a canon region. CH has no canton-level open
    /// publication (Mediapulse ranks per LANGUAGE region, which does not map
    /// onto the canton canon) — regional CH stays votes, as the order
    /// anticipated for non-open cases.
    static func regional(countryCode: String?, regionName: String) -> [String]? {
        let table: [String: [String]]
        switch countryCode?.uppercased() {
        case "DE": table = germanyRegional
        case "AT": table = austriaRegional
        default: return nil
        }
        // The picker may hand an ALIAS spelling (NRW) — resolve through the
        // canon entry first, then match tables by display key.
        let target = RadioRegionCanon.canonKey(regionName)
        let canon = RadioRegionCanon.tables[countryCode?.uppercased() ?? ""] ?? []
        let display = canon.first {
            RadioRegionCanon.canonKey($0.display) == target
                || $0.aliases.contains { RadioRegionCanon.canonKey($0) == target }
        }?.display ?? regionName
        let key = RadioRegionCanon.canonKey(display)
        return table.first { RadioRegionCanon.canonKey($0.key) == key }?.value
    }

    /// Official DOUBLE names the text ladder cannot bridge (the survey
    /// publishes one name, the broadcaster streams under the other). Tiny by
    /// design — a growing list here would mean the resolve ladder is broken.
    static func resolutionAliases(countryCode: String?) -> [String: [String]] {
        switch countryCode?.uppercased() {
        case "AT": return ["Österreich 1": ["Ö1"], "Ö 3": ["Ö3", "Hitradio Ö3"]]
        default: return [:]
        }
    }

    // MARK: - Germany

    /// Source: ma 2026 Audio II (agma), Hörer pro Durchschnittsstunde Mo–Fr,
    /// Einzelsender-Ranking as openly published by the trade press
    /// (radioszene.de/215607, full table, 2026-07). Round: ma 2026 Audio II.
    static let germanyNational: [String] = [
        "RADIO NRW",
        "BAYERN 1",
        "SWR3",
        "WDR 2",
        "Bayern Funkpaket",
        "ANTENNE BAYERN",
        "1LIVE",
        "BAYERN 3",
        "NDR 2",
        "RADIO BOB!",
        "bigFM (Gesamt)",
        "ROCK ANTENNE",
        "SWR1 BW",
        "HIT RADIO FFH",
        "SWR4 BW",
        "Absolut Radio",
        "radio ffn",
        "MDR SACHSEN",
        "hr3",
        "80s80s RADIO",
        "MDR JUMP",
        "bigFM biggste Beats",
        "ENERGY National",
        "Antenne Niedersachsen",
        "SUNSHINE LIVE",
        "hr4",
        "RPR1.",
        "R.SH Radio Schleswig-Holstein",
        "MDR THÜRINGEN",
        "SWR1 RP",
        "Klassik Radio",
        "RADIO BOLLERWAGEN",
        "hr1",
        "radio SAW",
        "Radio Schlagerparadies",
        "RADIO REGENBOGEN",
        "Hitradio antenne 1",
        "BR24",
        "Antenne Brandenburg",
        "Radio Hamburg",
        "OSTSEEWELLE",
        "Radio 7",
        "SWR4 RP",
        "bigFM BADEN-WÜRTTEMBERG",
        "SACHSEN FUNKPAKET",
        "90s90s RADIO",
        "RADIO PSR",
        "Bayern 2",
        "MDR SACHSEN-ANHALT",
        "radioeins",
        "Bremen Eins",
        "HITRADIO RTL SACHSEN",
        "89.0 RTL",
        "RADIO 21",
        "YOU FM (ab 1.6.26 DASDING vom hr)",
        "Radio Brocken",
        "ANTENNE THÜRINGEN",
        "104.6 RTL",
        "Berliner Rundfunk 91.4",
        "ENERGY DAB+ National",
        "DIE NEUE 107.7",
        "Radio Paloma",
        "rbb 88.8",
        "OLDIE ANTENNE",
        "BB RADIO",
        "STAR FM MAXIMUM ROCK",
        "planet radio",
        "Schwarzwaldradio",
        "RTL RADIO",
        "Schlager Radio",
        "SR 1",
        "rbb24 Inforadio",
        "R.SA",
        "94,3 rs2",
        "JAM FM",
        "ROCK ANTENNE Hamburg",
        "NIEDERSACHSEN FUNKPAKET",
        "Bremen Vier",
        "Niedersachsen Funkpaket",
        "Beats Radio",
        "ENERGY Sachsen",
        "Fritz",
        "RADIO BOB! rockt Schleswig-Holstein",
        "hr INFO",
        "SR 3 Saarlandwelle",
        "BR-KLASSIK",
        "Radio Arabella",
        "bigFM NRW",
        "Rockland Radio",
        "98.8 KISS FM",
        "Radio TEDDY",
        "HITRADIO OHR",
        "GONG 96.3 (München)",
        "die neue welle",
        "80er-Radio harmony",
        "105'5 Spreeradio",
        "LandesWelle Thüringen",
        "ENERGY Berlin",
        "Radio Ton",
        "RADIO SALÜ",
        "JAM FM Berlin",
        "TOGGO Radio",
        "ROCK FM",
        "ENERGY Bremen",
        "NOSTALGIE",
        "Radio Group City-Kombi",
        "Bremen NEXT",
        "egoFM",
        "100,5 DAS HITRADIO.",
        "100,6 FluxFM",
        "Donau 3 FM Baden-Württemberg",
        "delta radio",
        "ENERGY Region Stuttgart",
        "ENERGY Hamburg",
        "radio TOP 40",
        "Radio Seefunk",
        "Radio Paradiso",
        "baden.fm",
        "Radio Arabella Bayern",
        "ENERGY München",
        "95.5 Charivari (München)",
        "ROCKLAND",
        "Radio Cottbus",
        "HAMBURG ZWEI",
        "bigFM SAARLAND",
        "Radio Potsdam",
    ]

    /// Source: ma 2026 Audio II Top Ten per Bundesland by DAILY REACH, as
    /// openly published by MEEDIA (meedia.de/news/beitrag/24633, 2026-07-15;
    /// the per-state tables are open Datawrapper datasets in the article).
    /// Keyed by the canon display name (matched via canonKey, aliases fold).
    static let germanyRegional: [String: [String]] = [
        "Baden-Württemberg": [
            "SWR3",
            "SWR1 BW",
            "SWR4 BW",
            "bigFM",
            "Hitradio antenne 1",
            "Radio Regenbogen",
            "Radio 7",
            "DasDing / UnserDing",
            "Deutschlandfunk",
            "Die Neue 107.7",
        ],
        "Bayern": [
            "Bayern 1",
            "Bayern Funkpaket",
            "Antenne Bayern",
            "Bayern 3",
            "Rock Antenne",
            "BR24",
            "Bayern 2",
            "Radio Bob!",
            "Gong 96.3 (München)",
            "BR Heimat",
        ],
        "Berlin": [
            "radioeins",
            "104.6 RTL",
            "Berliner Rundfunk 91.4",
            "rbb 88.8",
            "Deutschlandfunk",
            "rbb24 Inforadio",
            "94,3 rs2",
            "98.8 Kiss FM",
            "Energy Berlin",
            "Star FM Maximum Rock",
        ],
        "Brandenburg": [
            "Antenne Brandenburg",
            "BB Radio",
            "104.6 RTL",
            "Berliner Rundfunk 91.4",
            "radioeins",
            "rbb24 Inforadio",
            "94,3 rs2",
            "rbb 88.8",
            "Fritz",
            "Deutschlandfunk",
        ],
        "Bremen": [
            "Bremen Eins",
            "Bremen Vier",
            "Energy Bremen",
            "Bremen Next",
            "NDR 2",
            "Bremen Zwei",
            "radio ffn",
            "Radio 21",
            "NDR Info",
            "Antenne Niedersachsen",
        ],
        "Hamburg": [
            "Radio Hamburg",
            "NDR 90,3",
            "NDR 2",
            "NDR Info",
            "Deutschlandfunk",
            "N-Joy",
            "Energy Hamburg",
            "Rock Antenne Hamburg",
            "R.SH Radio Schleswig-Holstein",
            "Hamburg Zwei",
        ],
        "Hessen": [
            "Hit Radio FFH",
            "hr3",
            "hr1",
            "hr4",
            "planet radio",
            "Radio Bob!",
            "You FM (seit 1.6. DasDing vom hr)",
            "hr Info",
            "Deutschlandfunk",
            "SWR3",
        ],
        "Mecklenburg-Vorpommern": [
            "NDR 1 Radio MV",
            "Ostseewelle",
            "NDR 2",
            "80s80s Radio",
            "N-Joy",
            "NDR Info",
            "Deutschlandfunk",
            "Radio Bob!",
            "Sunshine Live",
            "Absolut Radio",
        ],
        "Niedersachsen": [
            "NDR 1 Niedersachsen",
            "NDR 2",
            "radio ffn",
            "Antenne Niedersachsen",
            "N-Joy",
            "Radio 21",
            "NDR info",
            "89.0 RTL",
            "Niedersachsen Funkpaket",
            "Radio Bob!",
        ],
        "Nordrhein-Westfalen": [
            "Radio NRW",
            "WDR 2",
            "1Live",
            "WDR 4",
            "WDR 5",
            "Radio Bob!",
            "bigFM",
            "Deutschlandfunk",
            "WDR 3",
            "1Live Diggi",
        ],
        "Rheinland-Pfalz": [
            "SWR3",
            "RPR1.",
            "SWR1 RP",
            "bigFM",
            "SWR4 RP",
            "Rockland Radio",
            "Deutschlandfunk",
            "Hit Radio FFH",
            "Antenne NRW Premium",
            "DasDing / UnserDing",
        ],
        "Saarland": [
            "SR 1",
            "SR 3 Saarlandwelle",
            "Radio Salü",
            "bigFM",
            "SWR3",
            "DasDing / UnserDing",
            "RTL Radio",
            "Deutschlandfunk",
            "Radio Bob!",
            "SR kultur",
        ],
        "Sachsen": [
            "MDR Sachsen",
            "Sachsen Funkpaket",
            "Radio PSR",
            "MDR Jump",
            "Hitradio RTL Sachsen",
            "Energy Sachsen",
            "R.SA",
            "MDR aktuell",
            "Radio Bob!",
            "Deutschlandfunk",
        ],
        "Sachsen-Anhalt": [
            "radio SAW",
            "MDR Sachsen-Anhalt",
            "Radio Brocken",
            "MDR Jump",
            "89.0 RTL",
            "MDR Sputnik",
            "MDR aktuell",
            "Radio Bob!",
            "Absolut Radio",
            "NDR 1 Niedersachsen",
        ],
        "Schleswig-Holstein": [
            "R.SH Radio Schleswig-Holstein",
            "NDR 2",
            "NDR 1 Welle Nord",
            "Radio Hamburg",
            "N-Joy",
            "NDR Info",
            "NDR 90,3",
            "Radio Bob! rockt Schleswig-Holstein",
            "Deutschlandfunk",
            "delta radio",
        ],
        "Thüringen": [
            "MDR Thüringen",
            "Antenne Thüringen",
            "MDR Jump",
            "Landeswelle Thüringen",
            "Radio Bob!",
            "radio Top 40",
            "89.0 RTL",
            "MDR aktuell",
            "Deutschlandfunk",
            "MDR Kultur",
        ],
    ]

    // MARK: - Austria

    /// Source: Radiotest 2026_2 (GfK/RMS Austria), Tagesreichweite in Tsd,
    /// 10+ Mo–So, "Pressetabellen Radiotest 2026_2" openly published at
    /// rms-austria.at/mediaservice/radiotest. Aggregate rows (gesamt, RMS
    /// TOP, ALL-IN/marketing combinations, "im VG n") excluded — they are
    /// sales combinations, not stations. Round: Radiotest 2026_2 (07/2025–
    /// 06/2026).
    static let austriaNational: [String] = [
        "Ö 3",
        "kronehit",
        "Österreich 1",
        "88.6 - so rockt das Leben",
        "Radio Niederösterreich",
        "Radio Wien",
        "Radio Steiermark",
        "Radio Oberösterreich",
        "FM4",
        "Antenne Steiermark",
        "Life Radio (OÖ)",
        "Radio Salzburg",
    ]

    /// Source: same Pressetabellen, the nine Bundesland columns (10+ Mo–So).
    static let austriaRegional: [String: [String]] = [
        "Burgenland": [
            "Ö 3",
            "Radio Burgenland",
            "88.6 - so rockt das Leben",
            "kronehit",
            "Österreich 1",
            "Radio Niederösterreich",
            "Antenne Steiermark",
            "FM4",
            "Radio Wien",
            "Radio Steiermark",
        ],
        "Kärnten": [
            "Radio Kärnten",
            "Ö 3",
            "Antenne Kärnten",
            "kronehit",
            "Österreich 1",
            "FM4",
            "88.6 - so rockt das Leben",
            "Rock Antenne Österreich",
            "Radio Flamingo",
            "Antenne Hit",
        ],
        "Niederösterreich": [
            "Ö 3",
            "Radio Niederösterreich",
            "88.6 - so rockt das Leben",
            "kronehit",
            "Österreich 1",
            "Radio Wien",
            "Radio Arabella (W/NÖ/B)",
            "FM4",
            "ENERGY Österreich (W/NÖ/B)",
            "Radio Burgenland",
        ],
        "Oberösterreich": [
            "Ö 3",
            "Radio Oberösterreich",
            "Life Radio (OÖ)",
            "kronehit",
            "Österreich 1",
            "88.6 - so rockt das Leben",
            "FM4",
            "Radio Salzburg",
            "Radio Niederösterreich",
            "oe24",
        ],
        "Salzburg": [
            "Ö 3",
            "Radio Salzburg",
            "Österreich 1",
            "kronehit",
            "Antenne Salzburg",
            "FM4",
            "oe24",
            "Radio VM1",
            "Radio Oberösterreich",
            "88.6 - so rockt das Leben",
        ],
        "Steiermark": [
            "Ö 3",
            "Radio Steiermark",
            "Antenne Steiermark",
            "Österreich 1",
            "kronehit",
            "88.6 - so rockt das Leben",
            "Radio Grün-Weiss",
            "FM4",
            "Soundportal",
            "Radio Flamingo",
        ],
        "Tirol": [
            "Ö 3",
            "Radio Tirol",
            "Life Radio (Tirol)",
            "Radio U1 Tirol",
            "kronehit",
            "Österreich 1",
            "88.6 - so rockt das Leben",
            "FM4",
            "Antenne Tirol",
            "Rock Antenne Österreich",
        ],
        "Vorarlberg": [
            "Radio Vorarlberg",
            "ANTENNE VORARLBERG",
            "Ö 3",
            "kronehit",
            "Österreich 1",
            "FM4",
            "ANTENNE VORARLBERG Partymix",
            "oe24",
            "Rock Antenne Österreich",
            "Antenne Österreich",
        ],
        "Wien": [
            "Ö 3",
            "Radio Wien",
            "Österreich 1",
            "kronehit",
            "88.6 - so rockt das Leben",
            "ENERGY Österreich (W/NÖ/B)",
            "Radio Niederösterreich",
            "Radio Arabella (W/NÖ/B)",
            "FM4",
            "Superfly",
        ],
    ]

    // MARK: - Switzerland

    /// Source: Mediapulse Radio Data, Semester Publication 1. Halbjahr 2026
    /// (public Tableau workbook linked from mediapulse.ch/daten), daily reach
    /// Mo–So per channel. Mediapulse publishes per LANGUAGE region; the
    /// national order sums the three regions — they partition the survey
    /// universe, so the sum is the national daily reach (reconstruction, not
    /// curation). "Total …"/"other …" aggregate rows excluded. Round:
    /// 1. Halbjahr 2026.
    static let switzerlandNational: [String] = [
        "SRF 1",
        "Radio Swiss Pop",
        "SRF 3",
        "RTS Première",
        "SRF Musikwelle",
        "Pilatus",
        "Radio 24",
        "Energy Zürich",
        "Zürisee",
        "Central",
        "Vintage Radio",
        "Argovia",
        "FM1",
        "SRF 4 News",
        "Energy Bern",
        "Radio Melody",
        "Virgin Radio Switzerland",
        "LFM",
        "Flashback FM",
        "Radio Top",
        "RTS Option Musique",
        "Radio 1",
        "SRF 2 Kultur",
        "One FM",
        "Radio 32",
        "Basilisk",
        "Bern1",
        "Radio Swiss Classic",
        "Sunshine",
    ]
}
