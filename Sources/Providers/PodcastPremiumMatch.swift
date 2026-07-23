// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Y51: a premium feed replaces a free subscription of the same show. All
/// decision logic lives here, pure and CONSERVATIVE — a missed match is cheap
/// (the episode just stays unmatched), a wrong match would move progress onto
/// the wrong episode. Free/premium feeds do NOT share episode GUIDs, so the
/// match runs on enclosure URLs first (the proven Apple-import technique) and
/// falls back to title + publish-date proximity.
nonisolated enum PodcastPremiumMatch {
    /// Fallback window: premium copies are published around the free release,
    /// not at the identical timestamp.
    static let pubDateWindowMillis: Double = 48 * 3600 * 1000

    /// Lowercased, diacritic-folded, non-alphanumerics collapsed to single
    /// spaces — tolerant against punctuation/casing noise between feed variants.
    static func normalizedTitle(_ raw: String) -> String {
        raw.lowercased()
            .folding(options: [.diacriticInsensitive], locale: nil)
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    /// Conservative same-show test: equal, non-empty normalized titles. The
    /// user confirms the replacement anyway — this only decides whether to ASK.
    static func sameShow(titleA: String, titleB: String) -> Bool {
        let a = normalizedTitle(titleA)
        return !a.isEmpty && a == normalizedTitle(titleB)
    }

    /// freeGuid → premiumGuid. Primary: normalized enclosure URL equality.
    /// Fallback: normalized episode title UNIQUE on both sides AND publish
    /// dates within the window. Any ambiguity (duplicate enclosures/titles)
    /// yields NO match for the affected episodes.
    static func episodeMatches(
        free: [PodcastEpisode], premium: [PodcastEpisode]
    ) -> [String: String] {
        // Premium index by enclosure; collisions poison the key.
        var premiumByEnclosure: [String: String] = [:]
        var ambiguousEnclosures: Set<String> = []
        for ep in premium {
            let key = PodcastSubscriptions.normalizeEnclosure(ep.audioURL)
            guard !key.isEmpty else { continue }
            if premiumByEnclosure[key] != nil { ambiguousEnclosures.insert(key) }
            premiumByEnclosure[key] = ep.guid
        }

        var result: [String: String] = [:]
        var unmatchedFree: [PodcastEpisode] = []
        for ep in free {
            let key = PodcastSubscriptions.normalizeEnclosure(ep.audioURL)
            if !key.isEmpty, !ambiguousEnclosures.contains(key),
               let premiumGuid = premiumByEnclosure[key] {
                result[ep.guid] = premiumGuid
            } else {
                unmatchedFree.append(ep)
            }
        }

        // Title+date fallback for the rest — unique titles only, both sides.
        let matchedPremium = Set(result.values)
        var premiumByTitle: [String: [PodcastEpisode]] = [:]
        for ep in premium where !matchedPremium.contains(ep.guid) {
            let t = normalizedTitle(ep.title)
            guard !t.isEmpty else { continue }
            premiumByTitle[t, default: []].append(ep)
        }
        var freeTitleCounts: [String: Int] = [:]
        for ep in unmatchedFree {
            freeTitleCounts[normalizedTitle(ep.title), default: 0] += 1
        }
        for ep in unmatchedFree {
            let t = normalizedTitle(ep.title)
            guard !t.isEmpty, freeTitleCounts[t] == 1,
                  let candidates = premiumByTitle[t], candidates.count == 1,
                  abs(candidates[0].pubDate - ep.pubDate) <= pubDateWindowMillis
            else { continue }
            result[ep.guid] = candidates[0].guid
        }
        return result
    }
}
