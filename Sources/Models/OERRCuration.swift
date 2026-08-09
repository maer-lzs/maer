// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation

/// X²·3 (958d7d1): the public-broadcast RULE curation — a POSITIVE list of
/// broadcasters as data (the only list form; the criterion is neutral:
/// editorially independent public-service broadcasters with open full feeds;
/// curated list). Applied LIVE to the Apple directory (search + charts via
/// the existing clients); the hand-curated entries in `HoerspielCuration`
/// stay as seed/offline fallback. Visibility is language-driven: only the
/// active suggestion languages load their broadcasters.
nonisolated enum OERRCuration {
    /// The country axis of the sub-page (one tile row per country; empty
    /// countries do not appear — DIE REGEL).
    enum Country: String, CaseIterable {
        case germany, austria, switzerland, uk, australia, canada, newZealand,
             france, belgium, italy, spain, netherlands, sweden, norway,
             denmark, finland, portugal, japan, korea

        var title: String {
            switch self {
            case .germany: String(localized: "Germany")
            case .austria: String(localized: "Austria")
            case .switzerland: String(localized: "Switzerland")
            case .uk: String(localized: "United Kingdom")
            case .australia: String(localized: "Australia")
            case .canada: String(localized: "Canada")
            case .newZealand: String(localized: "New Zealand")
            case .france: String(localized: "France")
            case .belgium: String(localized: "Belgium")
            case .italy: String(localized: "Italy")
            case .spain: String(localized: "Spain")
            case .netherlands: String(localized: "Netherlands")
            case .sweden: String(localized: "Sweden")
            case .norway: String(localized: "Norway")
            case .denmark: String(localized: "Denmark")
            case .finland: String(localized: "Finland")
            case .portugal: String(localized: "Portugal")
            case .japan: String(localized: "Japan")
            case .korea: String(localized: "Korea")
            }
        }
    }

    struct Broadcaster {
        /// EXACT artist-name tokens (lowercased) — precision beats breadth
        /// (a substring "hr" would match "Uhr"; tokens don't).
        let tokens: [String]
        let country: Country
        let language: String
        /// The iTunes storefront the live search runs in.
        let storefront: String
        /// L2: terms that find THIS broadcaster. Empty ⇒ the language term
        /// (`searchTerms[language]`) carries it, as before.
        var searchTerms: [String] = []
    }

    /// Positivliste v1 (freigegeben 958d7d1). Who is missing is missing
    /// without remark — the criterion above is the whole rule.
    static let broadcasters: [Broadcaster] = [
        // German-language
        Broadcaster(tokens: ["ard", "wdr", "br", "hr", "hr2", "ndr", "swr", "mdr",
                             "rbb", "rundfunk berlin-brandenburg", "sr", "radio bremen"],
                    country: .germany, language: "de", storefront: "de"),
        Broadcaster(tokens: ["deutschlandfunk", "deutschlandfunk kultur", "deutschlandradio", "dlf"],
                    country: .germany, language: "de", storefront: "de"),
        Broadcaster(tokens: ["orf", "ö1"], country: .austria, language: "de", storefront: "de"),
        Broadcaster(tokens: ["srf", "schweizer radio und fernsehen"],
                    country: .switzerland, language: "de", storefront: "de"),
        // English-language
        Broadcaster(tokens: ["bbc", "bbc radio 4", "bbc sounds"],
                    country: .uk, language: "en", storefront: "gb"),
        // L2 (09.08., gemessen): der Sprach-Begriff „drama" findet in au/ca/nz
        // NUR die BBC (au 7/7 BBC, ca 2/2, nz 4/4 — kein einziger Treffer der
        // dortigen Anstalt). Deshalb tragen diese Anstalten EIGENE Begriffe;
        // gemessen: „ABC listen drama" → 19 ABC-Absender von 25, „CBC podcast
        // drama" → 9 CBC von 10, „RNZ drama" → 15 RNZ von 25.
        Broadcaster(tokens: ["abc", "abc listen", "australian broadcasting corporation"],
                    country: .australia, language: "en", storefront: "au",
                    searchTerms: ["ABC listen drama"]),
        Broadcaster(tokens: ["cbc", "cbc radio"], country: .canada, language: "en", storefront: "ca",
                    searchTerms: ["CBC podcast drama"]),
        Broadcaster(tokens: ["rnz", "radio new zealand"], country: .newZealand, language: "en", storefront: "nz",
                    searchTerms: ["RNZ drama", "RNZ storytime"]),
        // French-language
        Broadcaster(tokens: ["radio france", "france culture", "france inter"],
                    country: .france, language: "fr", storefront: "fr"),
        Broadcaster(tokens: ["rtbf"], country: .belgium, language: "fr", storefront: "be"),
        Broadcaster(tokens: ["rts"], country: .switzerland, language: "fr", storefront: "ch"),
        Broadcaster(tokens: ["radio-canada", "ici première"], country: .canada, language: "fr", storefront: "ca"),
        // Others
        Broadcaster(tokens: ["rsi"], country: .switzerland, language: "it", storefront: "ch"),
        Broadcaster(tokens: ["rtve", "radio nacional", "rne"], country: .spain, language: "es", storefront: "es"),
        Broadcaster(tokens: ["npo"], country: .netherlands, language: "nl", storefront: "nl"),
        Broadcaster(tokens: ["vrt"], country: .belgium, language: "nl", storefront: "be"),
        Broadcaster(tokens: ["sveriges radio", "sr drama"], country: .sweden, language: "sv", storefront: "se"),
        Broadcaster(tokens: ["nrk"], country: .norway, language: "no", storefront: "no"),
        Broadcaster(tokens: ["dr", "danmarks radio"], country: .denmark, language: "da", storefront: "dk"),
        Broadcaster(tokens: ["yle"], country: .finland, language: "fi", storefront: "fi"),
        Broadcaster(tokens: ["rtp"], country: .portugal, language: "pt", storefront: "pt"),
        Broadcaster(tokens: ["nhk"], country: .japan, language: "ja", storefront: "jp"),
        Broadcaster(tokens: ["kbs"], country: .korea, language: "ko", storefront: "kr"),
    ]

    /// The live-search term per language (what the genre is CALLED there).
    static let searchTerms: [String: String] = [
        "de": "Hörspiel", "en": "drama", "fr": "fiction radiophonique",
        "it": "radiodramma", "es": "ficción sonora", "nl": "hoorspel",
        "sv": "radioteater", "no": "radioteater", "da": "radiodrama",
        "fi": "kuunnelma", "pt": "radionovela", "ja": "ラジオドラマ", "ko": "라디오 드라마",
    ]

    /// Pure rule: does this artist name belong to a listed broadcaster?
    /// Token-exact over the name's words plus full-name containment for
    /// multi-word tokens — precision before breadth (X²·3 Auflage).
    static func matches(artistName: String?) -> Broadcaster? {
        guard let raw = artistName?.lowercased(), !raw.isEmpty else { return nil }
        let words = Set(raw.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init))
        for broadcaster in broadcasters {
            for token in broadcaster.tokens {
                if token.contains(" ") || token.contains("-") {
                    if raw.contains(token) { return broadcaster }
                } else if words.contains(token) {
                    return broadcaster
                }
            }
        }
        return nil
    }

    /// L2 (09.08., GEMESSEN und entscheidend): eine Absender-Regel allein
    /// reicht NICHT. Mit anstaltseigenen Suchbegriffen fuellen sich au/ca/nz
    /// zwar — aber mit Nachrichten und Talk: „Best of ABC Sport Podcast",
    /// „Checkpoint", „Front Burner", „Nine To Noon" bestehen die
    /// Absender-Regel muehelos. Eine Reihe „Oeffentlich-rechtliche
    /// Hoerspiele" mit ABC-Sport darin waere eine Falschaussage.
    ///
    /// Die Messung liefert die saubere Trennung gleich mit: ALLE echten
    /// Treffer (BBC „Dramas", „Limelight", „The Dark Is Rising", „Short
    /// Story") tragen Apples FORM-Kategorien `Drama`/`Fiction`; KEIN einziger
    /// der Fehltreffer tut das. Das ist derselbe Hebel wie beim Chart-
    /// Entscheid (Form-Kategorie schlaegt Themen-Kategorie).
    ///
    /// Fehlen die Kategorien ganz (Verzeichnis liefert sie nicht), gilt der
    /// Eintrag als NICHT belegt — wir nehmen nichts auf, dessen Form wir
    /// nicht kennen (dieselbe Linie wie bei der Rechtelage).
    static let fictionCategories: Set<String> = ["drama", "fiction", "science fiction",
                                                 "comedy fiction", "drama & fiction"]

    static func isFiction(categories: [String]?) -> Bool {
        guard let categories else { return false }
        return categories.contains { fictionCategories.contains($0.lowercased()) }
    }

    /// Broadcasters whose language is among the active suggestion languages.
    static func active(forLanguages codes: [String]) -> [Broadcaster] {
        broadcasters.filter { codes.contains($0.language) }
    }
}
