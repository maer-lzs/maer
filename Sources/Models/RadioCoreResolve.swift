// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation

/// Resolves the first-hand core-list NAMES (RadioListenerCores)
/// against the live Radio-Browser catalog. Pure and fixture-tested. The
/// ladder below was developed against the real DE/AT/CH catalogs (reference
/// run in the delivery report); every rule exists because a real station
/// needed it. What doesn't resolve is RETURNED as a miss, never silently
/// skipped. The caller logs it and the quote goes into the report.
nonisolated enum RadioCoreResolve {

    /// A resolved core: stations in CORE (published-rank) order, plus the
    /// honest remainder.
    struct Resolution {
        let stations: [RadioStation]
        let misses: [String]
        /// core name → catalog name, for the log (renames are visible).
        let mapping: [(core: String, matched: String)]
    }

    // MARK: - Folding

    /// Diacritic-folded, lowercased, alphanumerics only ("Ö 3" → "o3").
    static func foldKey(_ s: String) -> String {
        tokens(s).joined()
    }

    /// Folded word tokens ("R.SH Radio" → ["r","sh","radio"]).
    static func tokens(_ s: String) -> [String] {
        let folded = s.folding(options: [.diacriticInsensitive, .caseInsensitive],
                               locale: Locale(identifier: "en_US_POSIX"))
        return folded.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
    }

    /// All CONTIGUOUS token concatenations ("orf hitradio ö3" →
    /// orf, hitradio, o3, orfhitradio, hitradioo3, orfhitradioo3). The
    /// n-gram joins are what bridge broadcaster prefixes ("ORF Radio Wien"),
    /// "Radio X" catalog names ("Radio Pilatus" for "Pilatus") and glued
    /// spellings ("Radio24") without one special case per pattern.
    static func joins(_ tokens: [String]) -> Set<String> {
        var out = Set<String>()
        for i in tokens.indices {
            var acc = ""
            for j in i..<tokens.count {
                acc += tokens[j]
                out.insert(acc)
            }
        }
        return out
    }

    // MARK: - Core name forms

    /// The alternative FORMS a published core name may take in the catalog.
    /// Region knowledge comes from the canon tables (abbreviation → full
    /// name, and region-word stripping for names like "R.SH Radio
    /// Schleswig-Holstein" → "R.SH"); the tiny alias table in
    /// RadioListenerCores covers official double names (Ö 3 / Hitradio Ö3).
    static func coreForms(_ name: String, countryCode: String?) -> [String] {
        var forms = [name, RadioMapping.displayName(name), strippingParens(name)]
        // Survey names use a plain ASCII " - " claim separator ("88.6 - so
        // rockt das Leben") that displayName deliberately does not cut.
        // Catalog names carry the head ("radio 88.6").
        if let range = name.range(of: " - "), name.distance(from: name.startIndex, to: range.lowerBound) >= 2 {
            forms.append(String(name[..<range.lowerBound]))
        }
        forms += RadioListenerCores.resolutionAliases(countryCode: countryCode)[name] ?? []
        let canon = RadioRegionCanon.tables[countryCode?.uppercased() ?? ""] ?? []
        // Trailing region abbreviation → the full display name (SWR1 RP →
        // SWR1 Rheinland-Pfalz).
        for entry in canon {
            for alias in entry.aliases where name.hasSuffix(" " + alias) {
                forms.append(String(name.dropLast(alias.count)) + entry.display)
            }
        }
        // TRAILING region words (display + aliases) and the filler "radio"
        // stripped from the end. "Donau 3 FM Baden-Württemberg" → "Donau 3
        // FM", "R.SH Radio Schleswig-Holstein" → "R.SH". Trailing only: a
        // region word inside a brand ("Radio Wien" itself) must survive, so
        // the strip stops before it would leave less than two tokens (one
        // suffices when it still carries three characters, "SWR4").
        var regionWords = Set<String>()
        for entry in canon {
            regionWords.formUnion(tokens(entry.display))
            for alias in entry.aliases { regionWords.formUnion(tokens(alias)) }
        }
        var kept = tokens(name)
        while let last = kept.last, regionWords.contains(last) || last == "radio" {
            let remaining = kept.count - 1
            guard remaining >= 2 || (remaining == 1 && kept[0].count >= 3) else { break }
            kept.removeLast()
        }
        // Never emit filler-only ("Radio Wien" must not become "radio".
        // That form matched Radio Pilatus by votes in the fixture run).
        if kept.count < tokens(name).count, kept != ["radio"] {
            forms.append(kept.joined(separator: " "))
        }
        return forms.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    /// Lookup queries for a core name the pool did not carry. Ordered, the
    /// caller searches them until one resolves: exact base name first, then
    /// the region-stripped form, the prefix before a "Radio …" tail ("R.SH"
    /// from "R.SH Radio Schleswig-Holstein"), and the name minus leading
    /// number tokens ("DAS HITRADIO" from "100,5 DAS HITRADIO.").
    static func lookupQueries(_ name: String, countryCode: String?) -> [String] {
        var queries = [strippingParens(name)]
        // The prefix before a "Radio …" tail comes BEFORE the folded forms.
        // It keeps the original spelling ("R.SH"), which the catalog's
        // substring search needs; the folded twin would dedupe it away.
        if let range = name.range(of: "Radio"), range.lowerBound != name.startIndex {
            queries.append(String(name[..<range.lowerBound])
                .trimmingCharacters(in: CharacterSet(charactersIn: " .-")))
        }
        let forms = coreForms(name, countryCode: countryCode)
        if forms.count > 3 { queries += forms[3...] }
        let words = name.split(separator: " ")
        if let first = words.first, words.count > 1,
           String(first).rangeOfCharacter(from: .letters) == nil {
            queries.append(words.dropFirst().joined(separator: " ")
                .trimmingCharacters(in: CharacterSet(charactersIn: " .,")))
        }
        var seen = Set<String>()
        return queries.filter { $0.count >= 3 && seen.insert(foldKey($0)).inserted }
    }

    private static func strippingParens(_ s: String) -> String {
        s.replacingOccurrences(of: "\\([^)]*\\)", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }

    // MARK: - Resolution

    /// Resolve core names against a catalog pool, preserving CORE order.
    /// Rule ladder per name (first rule with candidates wins, best votes
    /// within a rule): 1 raw-key equality · 2 display-cut equality ·
    /// 3 core key appears as a contiguous join of the catalog name
    /// ("Bayern 1" in "Bayern 1 Oberbayern") · 4 catalog key appears as a
    /// contiguous join of the core name ("antenne 1" in "Hitradio
    /// antenne 1"). Every core key is a COMPLETE form ("Ö1"), so even the
    /// two-character keys may join. A partial key never enters coreKeys.
    static func resolve(core: [String], pool: [RadioStation],
                        countryCode: String?) -> Resolution {
        struct PoolEntry {
            let station: RadioStation
            let rawKey: String
            let cutKey: String
            let poolTokens: [String]
            let poolJoins: Set<String>
            let votes: Int
        }
        var entries: [PoolEntry] = []
        var seenIDs = Set<String>()
        for station in pool where seenIDs.insert(station.id).inserted {
            let raw = foldKey(station.name)
            let toks = tokens(station.name)
            entries.append(PoolEntry(
                station: station,
                rawKey: raw,
                cutKey: foldKey(RadioMapping.displayName(station.name)),
                poolTokens: toks,
                poolJoins: joins(toks),
                votes: station.votes ?? 0))
        }
        // Rule-3 proximity: how many catalog tokens the matched join does
        // NOT cover. "radio 88.6" (1 leftover) must beat the sub-brand
        // "88.6 Hard Rock" (2 leftovers) even though the sub-brand out-votes
        // it. Closeness first, votes only within equal closeness.
        func leftover(_ entry: PoolEntry, matching keys: [String]) -> Int {
            var best = entry.poolTokens.count
            for key in keys where entry.poolJoins.contains(key) {
                for start in entry.poolTokens.indices {
                    var acc = ""
                    for end in start..<entry.poolTokens.count {
                        acc += entry.poolTokens[end]
                        if acc == key {
                            best = min(best, entry.poolTokens.count - (end - start + 1))
                        }
                        if acc.count >= key.count { break }
                    }
                }
            }
            return best
        }
        var stations: [RadioStation] = []
        var misses: [String] = []
        var mapping: [(String, String)] = []
        var taken = Set<String>()
        for coreName in core {
            let forms = coreForms(coreName, countryCode: countryCode)
            let coreKeys = forms.map(foldKey).filter { !$0.isEmpty }
            var coreJoins = Set<String>()
            for form in forms { coreJoins.formUnion(joins(tokens(form))) }
            var best: PoolEntry?
            for rule in 1...4 {
                let candidates = entries.filter { entry in
                    guard !taken.contains(entry.station.id) else { return false }
                    switch rule {
                    case 1: return coreKeys.contains(entry.rawKey)
                    case 2: return coreKeys.contains(entry.cutKey)
                    case 3: return coreKeys.contains {
                        $0.count >= 2 && entry.poolJoins.contains($0)
                    }
                    default: return entry.rawKey.count >= 4 && coreJoins.contains(entry.rawKey)
                    }
                }
                let winner = rule == 3
                    ? candidates.min { a, b in
                        let la = leftover(a, matching: coreKeys)
                        let lb = leftover(b, matching: coreKeys)
                        return la == lb ? a.votes > b.votes : la < lb
                    }
                    : candidates.max { $0.votes < $1.votes }
                if let winner {
                    best = winner
                    break
                }
            }
            if let best {
                taken.insert(best.station.id)
                stations.append(best.station)
                if foldKey(coreName) != best.rawKey {
                    mapping.append((coreName, best.station.name))
                }
            } else {
                misses.append(coreName)
            }
        }
        return Resolution(stations: stations, misses: misses, mapping: mapping)
    }
}
