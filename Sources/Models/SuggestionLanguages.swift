// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// f79c40c/2ee3c32: the SUGGESTION language(s) — which languages catalog and
/// recommendation requests prefer (Discover row, podcast catalog/genre
/// charts, PI `lang`). MULTI-select; the device locale is the default; the
/// explicit choice beats the guess (the radio country-cascade principle).
/// Deliberately NOT the app language (that stays the iOS system setting).
/// 0b7a9ff: THE service-name truth — every network-feature toggle names its
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
    /// The choosable set — common podcast catalog languages; the device
    /// language is merged in even when exotic.
    static let choosable: [String] = [
        "de", "en", "fr", "es", "it", "nl", "pt", "sv", "no", "da", "fi", "pl", "ja", "ko",
    ]

    /// Effective selection: stored codes, else the device language (pure —
    /// locale injected for tests).
    static func effective(stored: [String]?, localeLanguage: String?) -> [String] {
        if let stored, !stored.isEmpty { return stored }
        if let lang = localeLanguage, !lang.isEmpty { return [lang] }
        return ["en"]
    }

    /// iTunes is STOREFRONT-bound, not language-bound — one representative
    /// storefront per language (charts are fetched per selected language and
    /// fairly interleaved; honest approximation, documented).
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
        effective(stored: UserDefaults.standard.stringArray(forKey: AppStorageKeys.suggestionLanguages),
                  localeLanguage: Locale.current.language.languageCode?.identifier)
    }
}
