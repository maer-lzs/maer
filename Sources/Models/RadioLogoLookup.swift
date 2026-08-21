// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

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
            let description: String?
        }
        let search: [Hit]?
    }

    /// CONSERVATIVE entity pick — a color tile beats a wrong logo (the
    /// portrait-chain principle): the first hit whose label folds to a
    /// mutual containment with the station name; nothing matching → nil.
    ///
    /// e0a0788 guard, measured on the seven decided cases (five foreign, two
    /// legitimate look-alikes): a label that is a PROPER subset of the
    /// station name proves nothing by text alone — "Life" ⊂ "Life Radio
    /// (OÖ)" is a magazine, "Reshet" ⊂ "Reshet Aleph" a TV house, while
    /// "Polskie Radio" ⊂ "Polskie Radio Białystok" is the broadcaster and
    /// "90s90s" ⊂ "90s90s Dance HQ" the brand. The DISCRIMINATOR the data
    /// actually carries (measured against the live search API): a radio word
    /// in the label or the entity DESCRIPTION. Not "broadcast" — Reshet's
    /// description says "television broadcasting"; Polskie carries its radio
    /// word in the LABEL, 90s90s in the description ("radio station").
    static func matchedEntity(fromSearchData data: Data, stationName: String)
        -> (id: String, label: String)? {
        guard let decoded = try? JSONDecoder().decode(SearchResponse.self, from: data) else { return nil }
        let wanted = fold(stationName)
        guard !wanted.isEmpty else { return nil }
        for hit in decoded.search ?? [] {
            guard let id = hit.id, let label = hit.label else { continue }
            let have = fold(label)
            guard !have.isEmpty else { continue }
            if have == wanted { return (id, label) }
            if wanted.contains(have) {
                let evidence = have + fold(hit.description ?? "")
                guard ["radio", "rundfunk", "horfunk"].contains(where: evidence.contains)
                else { continue }
                return (id, label)
            }
            if have.contains(wanted) { return (id, label) }
        }
        return nil
    }

    /// e0a0788, the file-level witness (the generator's Namens-Wache, ported
    /// to the runtime stage that PERSISTS): the P154 file must carry the
    /// matched label — "Reset Media.svg" does not carry "Reshet", and a
    /// positive that never expires must not be booked on a file that answers
    /// for a different house.
    static func fileCarriesLabel(_ fileName: String, label: String) -> Bool {
        let foldedLabel = fold(label)
        return foldedLabel.count >= 4 && fold(fileName).contains(foldedLabel)
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
    /// 2765161: houses declare MANY sizes, and by convention the FIRST tag
    /// is often the smallest — sportschau lists 57 first and 152 later, and
    /// taking the first put a mushy 57-px icon on every Bundesliga tile.
    /// The pick is the LARGEST declared variant; tags without a `sizes`
    /// attribute stay usable as the fallback.
    static func extractTouchIcon(html: String, baseURL: URL) -> URL? {
        var best: (url: URL, size: Int)?
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
            guard let url = URL(string: href, relativeTo: baseURL)?.absoluteURL,
                  url.scheme?.hasPrefix("http") == true else { continue }
            // A tag WITHOUT a sizes attribute is Apple's modern default and
            // by convention large (180) — scoring it 0 would let a legacy
            // sizes="57x57" beat it, the very class this fix kills.
            var declared = 180
            if let sizesRange = tag.range(of: "sizes=\"", options: .caseInsensitive) {
                let tail = tag[sizesRange.upperBound...]
                declared = Int(tail.prefix(while: \.isNumber)) ?? 0
            }
            if best == nil || declared > best!.size { best = (url, declared) }
        }
        return best?.url
    }

    // MARK: - 4e1688d: the sibling entries of the SAME station

    /// The catalog carries the same station several times, and the entry with
    /// the most votes is not always the one with a picture: bigFM Deutschland
    /// has 497 votes and an EMPTY favicon, while its 88-vote sibling carries a
    /// 600×600 image. Our pick takes the strongest and inherits its gap.
    ///
    /// Measured before building (top 200 of DE/CH/AT, 281 stations without a
    /// favicon):
    ///
    /// | rule | hits |
    /// |---|---|
    /// | same homepage DOMAIN only | 74 % — but wrong: `laut.fm` is a platform, not a station |
    /// | domain + NAME KINSHIP | **24 %, no wrong hit in 281 cases** |
    /// | identical homepage URL + name kinship | 13 % |
    ///
    /// The middle rule is the one built. Its extra hits over the strict one
    /// are station FAMILIES (Sunshine Live's sub-channels, Radio Swiss Classic's
    /// language variants) — exactly the case this is for. The name kinship is
    /// what keeps a hosting platform's unrelated stations out, and a wrong logo
    /// is worse than a colour tile.
    static func siblingSearchURL(name: String, mirror: String) -> URL? {
        var comps = URLComponents(string: mirror + "/json/stations/search")
        comps?.queryItems = [
            URLQueryItem(name: "name", value: brandStem(of: name)),
            URLQueryItem(name: "limit", value: "40"),
            URLQueryItem(name: "hidebroken", value: "true"),
            URLQueryItem(name: "order", value: "votes"),
            URLQueryItem(name: "reverse", value: "true"),
        ]
        return comps?.url
    }

    /// The searchable stem: the part before a family suffix, so
    /// "Sunshine Live - Techno" finds the siblings of "Sunshine Live".
    static func brandStem(of name: String) -> String {
        let head = name.components(separatedBy: " - ").first ?? name
        let trimmed = head.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.count >= 3 ? trimmed : name
    }

    /// Two catalog entries mean the same station when one name is the HEAD of
    /// the other (folded, ≥3 characters). Deliberately not a similarity score:
    /// a threshold nobody can name is how a wrong logo gets in.
    static func namesAreKin(_ a: String, _ b: String) -> Bool {
        let x = RadioBrowseCuration.mergeKey(a), y = RadioBrowseCuration.mergeKey(b)
        guard x.count >= 3, y.count >= 3 else { return false }
        return x.hasPrefix(y) || y.hasPrefix(x)
    }

    /// The best sibling favicon from a Radio Browser search answer: same
    /// homepage host, kin name, most votes first. Nil when nothing qualifies.
    static func siblingFaviconURL(fromSearchData data: Data, stationName: String,
                                  homepage: String?) -> URL? {
        let host = PodcastSubscriptions.feedHost(homepage ?? "")
        guard !host.isEmpty,
              let raw = try? JSONDecoder().decode([RadioBrowserStation].self, from: data)
        else { return nil }
        return raw
            .filter { entry in
                guard let favicon = entry.favicon?.trimmingCharacters(in: .whitespaces),
                      !favicon.isEmpty else { return false }
                guard PodcastSubscriptions.feedHost(entry.homepage ?? "") == host else { return false }
                return namesAreKin(stationName, entry.name)
            }
            .sorted { ($0.votes ?? 0) > ($1.votes ?? 0) }
            .lazy
            .compactMap { URL(string: $0.favicon ?? "") }
            .first { $0.scheme?.hasPrefix("http") == true }
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
