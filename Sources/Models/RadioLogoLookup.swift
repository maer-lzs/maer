// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// e4bd910/Ketten-Korrektur: the FINAL agreed radio-logo source chain —
/// gated RB favicon → **Wikidata P154 first** (the best logos for the
/// most-heard stations) → apple-touch-icon of the station homepage
/// (first-party) → gradient+initials placeholder. Google/DDG/Clearbit
/// deliberately NOT. Pure pieces here; the network actor throttles/caches.
nonisolated enum RadioLogoLookup {

    /// Wikidata entity search by station name (wbsearchentities).
    static func wikidataSearchURL(name: String, language: String = "de") -> URL? {
        var comps = URLComponents(string: "https://www.wikidata.org/w/api.php")
        comps?.queryItems = [
            URLQueryItem(name: "action", value: "wbsearchentities"),
            URLQueryItem(name: "search", value: name),
            URLQueryItem(name: "language", value: language),
            URLQueryItem(name: "uselang", value: language),
            URLQueryItem(name: "type", value: "item"),
            URLQueryItem(name: "limit", value: "5"),
            URLQueryItem(name: "format", value: "json"),
        ]
        return comps?.url
    }

    /// 275f379 (Diagnose-getrieben): search-term variants — the full name in
    /// de missed "90s90s Dance HQ" although Q105475115 ("90s90s", WITH a
    /// P154 logo) exists. Order: full name, then the BRAND stem (first word,
    /// ≥4 chars, only for multi-word names — "Rock Antenne" keeps both words
    /// via the containment match anyway). The conservative fold-match stays
    /// the safety net against wrong logos.
    static func searchTerms(for name: String) -> [String] {
        var terms = [name]
        // Family suffix ("Sunshine Live - Techno", "Hit Radio FFH - 80er"):
        // the brand prefix before " - " is the Wikidata-findable entity —
        // measured on the DE top 50, most gate misses are these families.
        if let dash = name.range(of: " - ") {
            let prefix = name[..<dash.lowerBound].trimmingCharacters(in: .whitespaces)
            if prefix.count >= 4, !terms.contains(prefix) { terms.append(prefix) }
        }
        let words = name.split(separator: " ")
        if words.count >= 2, words[0].count >= 4, !terms.contains(String(words[0])) {
            terms.append(String(words[0]))
        }
        return terms
    }

    private struct SearchResponse: Decodable {
        struct Hit: Decodable {
            let id: String?
            let label: String?
        }
        let search: [Hit]?
    }

    /// CONSERVATIVE entity pick — a color tile beats a wrong logo (the
    /// portrait-chain principle): the first hit whose label folds to a
    /// mutual containment with the station name; nothing matching → nil.
    static func matchedEntityId(fromSearchData data: Data, stationName: String) -> String? {
        guard let decoded = try? JSONDecoder().decode(SearchResponse.self, from: data) else { return nil }
        let wanted = fold(stationName)
        guard !wanted.isEmpty else { return nil }
        for hit in decoded.search ?? [] {
            guard let id = hit.id, let label = hit.label else { continue }
            let have = fold(label)
            if !have.isEmpty, have.contains(wanted) || wanted.contains(have) { return id }
        }
        return nil
    }

    private static func fold(_ raw: String) -> String {
        raw.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .lowercased()
            .filter { $0.isLetter || $0.isNumber }
    }

    /// P154 (logo image) via the SHARED claim parser of the portrait chain.
    static func p154FileName(fromEntityData data: Data, entity: String) -> String? {
        ArtistPortraitLookup.claimFileName(fromEntityData: data, entity: entity, property: "P154")
    }

    /// apple-touch-icon extraction — one light tag scan (the itunes:image
    /// pattern), href resolved against the page URL; nil when absent.
    static func extractTouchIcon(html: String, baseURL: URL) -> URL? {
        var searchStart = html.startIndex
        while let linkRange = html.range(of: "<link", range: searchStart..<html.endIndex) {
            guard let tagEnd = html.range(of: ">", range: linkRange.upperBound..<html.endIndex) else { break }
            let tag = html[linkRange.lowerBound..<tagEnd.upperBound]
            searchStart = tagEnd.upperBound
            guard tag.range(of: "apple-touch-icon", options: .caseInsensitive) != nil,
                  let hrefRange = tag.range(of: "href=\"", options: .caseInsensitive) else { continue }
            let after = tag[hrefRange.upperBound...]
            guard let end = after.firstIndex(of: "\"") else { continue }
            let href = String(after[..<end])
            if let url = URL(string: href, relativeTo: baseURL)?.absoluteURL,
               url.scheme?.hasPrefix("http") == true {
                return url
            }
        }
        return nil
    }

    /// The convention fallback when the page names no icon tag.
    static func conventionTouchIconURL(homepage: URL) -> URL? {
        guard var comps = URLComponents(url: homepage, resolvingAgainstBaseURL: false) else { return nil }
        comps.path = "/apple-touch-icon.png"
        comps.query = nil
        comps.fragment = nil
        return comps.url
    }
}
