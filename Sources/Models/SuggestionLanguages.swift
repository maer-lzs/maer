// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation

/// The SUGGESTION language(s). Which languages catalog and
/// recommendation requests prefer (Discover row, podcast catalog/genre
/// charts, PI `lang`). MULTI-select; the device locale is the default; the
/// explicit choice beats the guess (the radio country-cascade principle).
/// Deliberately NOT the app language (that stays the iOS system setting).
/// THE service-name truth. Every network-feature toggle names its
/// exact external services in its footnote, with the SAME strings the
/// network-services page shows (shared data, never typed twice). Transparency
/// at the point of decision.
nonisolated enum NetworkServiceNames {
    static let artistImages = "MusicBrainz · Wikidata · Wikimedia Commons"
    static let hiResCovers = "Cover Art Archive"
    static let lyrics = "LRCLIB"
    static let appleCatalog = "Apple Podcasts catalog"
    static let radioBrowser = "Radio Browser"
    static let librivox = "LibriVox"
    static let internetArchive = "Internet Archive"
    static let jamendo = "Jamendo"
    /// Catalog master: everything the free-catalog surfaces may talk to.
    static let freeCatalogs = "\(librivox) · \(internetArchive) · \(jamendo)"
}

nonisolated enum SuggestionLanguages {
    /// The choosable set. Common podcast catalog languages; the device
    /// language is merged in even when exotic.
    static let choosable: [String] = [
        "de", "en", "fr", "es", "it", "nl", "pt", "sv", "no", "da", "fi", "pl", "ja", "ko",
    ]

    /// Effective selection: stored codes, else the device language (pure.
    /// Locale injected for tests).
    static func effective(stored: [String]?, localeLanguage: String?) -> [String] {
        if let stored, !stored.isEmpty { return stored }
        if let lang = localeLanguage, !lang.isEmpty { return [lang] }
        return ["en"]
    }

    /// iTunes is STOREFRONT-bound, not language-bound. One representative
    /// storefront per language (charts are fetched per selected language and
    /// fairly interleaved; honest approximation, documented).
    /// A language is NOT one market. Measured on the Drama chart
    /// (1484, 50 entries each): GB deviates from the US chart in 15 of 50
    /// entries, AU in 18, CA in 14, IE in 22. And NZ in 28, i.e. 56 %. Only
    /// asking `us` for "English" silently hides that half; the overlap sits
    /// at the top (Sherlock, The Archers), the difference in the middle,
    /// which is exactly where the interesting radio plays live.
    ///
    /// The FIRST entry stays the previous single storefront, so nothing
    /// changes for languages with one market. Extending = a data entry.
    static let storefrontsByLanguage: [String: [String]] = [
        "de": ["de", "at", "ch"],
        "en": ["us", "gb", "au", "nz", "ca", "ie"],
        "fr": ["fr", "be", "ch", "ca"],
        "es": ["es", "mx", "ar", "co", "cl"],
        "pt": ["pt", "br"],
        "it": ["it", "ch"],
        "nl": ["nl", "be"],
    ]

    /// The storefronts of a language for THIS run: the primary market always,
    /// plus a rotating window over the rest. The day rotation of the radio
    /// rows, reused. Reason: languages × genres × storefronts grows fast; two
    /// per run keeps the request count flat while the variety still arrives
    /// over the week. `perRun` = 2 by default (primary + one rotating).
    /// The DEVICE REGION leads when it is in the language's
    /// list. Priority, not exclusivity. A device can sit in Switzerland, and
    /// the Swiss chart deviates from the German one by 58 % (measured), with
    /// content that is genuinely different: "Schreckmümpfeli" (the SRF
    /// short-play institution) stands there and nowhere else. Notably, the
    /// podcast route delivers exactly the Swiss material that the SRG API
    /// denies us legally. Without any grey zone.
    ///
    /// This reads the device REGION (same source the suggestion language
    /// takes its default from), not a location. No permission involved.
    static func storefronts(for language: String, perRun: Int = 2,
                            daySeed: Int = RediscoverSections.daySeed(for: Date()),
                            deviceRegion: String? = Locale.current.region?.identifier) -> [String] {
        var all = storefrontsByLanguage[language.lowercased()] ?? [storefront(for: language)]
        // Device region to the front when the language actually serves it.
        if let region = deviceRegion?.lowercased(),
           let index = all.firstIndex(of: region), index > 0 {
            all.remove(at: index)
            all.insert(region, at: 0)
        }
        guard all.count > 1, perRun > 1 else { return [all[0]] }
        let others = Array(all.dropFirst())
        let take = min(perRun - 1, others.count)
        let offset = abs(daySeed) % others.count
        let rotated = (0..<take).map { others[(offset + $0) % others.count] }
        return [all[0]] + rotated
    }

    static func storefront(for language: String) -> String {
        switch language.lowercased() {
        case "de": return "de"
        case "en": return "us"
        case "fr": return "fr"
        case "es": return "es"
        case "it": return "it"
        case "nl": return "nl"
        case "pt": return "br"
        case "sv": return "se"
        case "no": return "no"
        case "da": return "dk"
        case "fi": return "fi"
        case "pl": return "pl"
        case "ja": return "jp"
        case "ko": return "kr"
        default: return language.lowercased()
        }
    }

    /// PodcastIndex takes a REAL language list (comma-joined 2-letter codes).
    static func podcastIndexLangParameter(_ languages: [String]) -> String {
        languages.map { $0.lowercased() }.joined(separator: ",")
    }

    /// Runtime accessor (UserDefaults-backed; the pure pieces above stay
    /// injectable for tests).
    @MainActor
    static func current() -> [String] {
        effective(stored: AppStorageKeys.stringArray(AppStorageKeys.suggestionLanguages),
                  localeLanguage: Locale.current.language.languageCode?.identifier)
    }
}
