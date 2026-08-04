// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// 70dd0d8/d05124b: the recommendation categories only help if they reach
/// the QUERY. Feed categories come from `<itunes:category>` in Apple's
/// spelling — including the compound names with "&" — while the two
/// directories want something else:
///
/// - **PodcastIndex** keeps the parts SEPARATE ("Society" 77 and "Culture"
///   78; there is no "Society & Culture" entry). A compound name matches
///   nothing and, worse, eats one of the few capped `cat` slots — which is
///   exactly why the strongest signals fell out of the filter and only
///   generic trending was left.
/// - **iTunes charts** want a numeric genre id.
///
/// Pure data, conservative: an unknown category yields nothing rather than a
/// guess. Extending means adding an entry.
nonisolated enum PodcastCategoryMapping {
    /// Apple category → the PodcastIndex category names it decomposes into.
    /// Only entries verified against the podcast-namespace `categories.json`.
    static let podcastIndexByApple: [String: [String]] = [
        "society & culture": ["Society", "Culture"],
        "health & fitness": ["Health", "Fitness"],
        "religion & spirituality": ["Religion", "Spirituality"],
        "tv & film": ["TV", "Film"],
        "kids & family": ["Kids", "Family"],
        "arts": ["Arts"],
        "business": ["Business"],
        "comedy": ["Comedy"],
        "documentary": ["Documentary"],
        "education": ["Education"],
        "fiction": ["Fiction"],
        "government": ["Government"],
        "history": ["History"],
        "leisure": ["Leisure"],
        "music": ["Music"],
        "news": ["News"],
        "philosophy": ["Philosophy"],
        "science": ["Science"],
        "sports": ["Sports"],
        "technology": ["Technology"],
        "true crime": ["True Crime"],
    ]

    /// Apple category → iTunes chart genre id (the keyless branch).
    static let itunesGenreByApple: [String: Int] = [
        "arts": 1301,
        "business": 1321,
        "comedy": 1303,
        "education": 1304,
        "fiction": 1483,
        "government": 1511,
        "health & fitness": 1512,
        "history": 1487,
        "kids & family": 1305,
        "leisure": 1502,
        "music": 1310,
        "news": 1489,
        "religion & spirituality": 1314,
        "science": 1533,
        "society & culture": 1324,
        "sports": 1545,
        "technology": 1318,
        "true crime": 1488,
        "tv & film": 1309,
    ]

    /// Feed categories → PodcastIndex category terms, in the categories'
    /// own order, deduped. **The caller caps AFTER this call** — otherwise
    /// dead compound names use up the slots (the measured bug).
    static func podcastIndexCategories(for categories: [String]) -> [String] {
        var out: [String] = []
        var seen = Set<String>()
        for category in categories {
            for term in podcastIndexByApple[normalize(category)] ?? [] where seen.insert(term).inserted {
                out.append(term)
            }
        }
        return out
    }

    /// Feed categories → iTunes genre ids, order kept, deduped.
    static func itunesGenreIds(for categories: [String]) -> [Int] {
        var out: [Int] = []
        var seen = Set<Int>()
        for category in categories {
            guard let id = itunesGenreByApple[normalize(category)] else { continue }
            if seen.insert(id).inserted { out.append(id) }
        }
        return out
    }

    /// The Apple category a genre id came from — lets the recommendation
    /// REASON name the real category instead of claiming "popular".
    static func appleCategory(forGenreId id: Int) -> String? {
        itunesGenreByApple.first { $0.value == id }?.key
    }

    private static func normalize(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: " and ", with: " & ", options: .caseInsensitive)
            .lowercased()
    }
}
