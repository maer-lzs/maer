// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation

/// Pure, testable ranking for the Home aggregation tab (Etappe 3). The Home tab
/// is a cross-section of the media libraries; its sections rank STRICTLY by
/// timestamp (no heuristics). This core merges id/timestamp pairs from several
/// sources; the view resolves the ids back to items via AppSession.
nonisolated enum HomeSections {
    /// Max music entries in the Continue row. A constant, not a setting.
    /// Since music titles left the row this caps the playlists only.
    static let continueMusicCap = 2

    /// Music never stands in "Continue": an album, a song or a catalogue
    /// title that is not a reading lives in "Listen Again", with or without
    /// a position, so a title cannot flip between the two rows while its
    /// position travels. Spoken word stays. The ONE form question decides
    /// (`MediaFamily.isMusicByForm`); a music PLAYLIST in progress is a
    /// list, not a title, and keeps its continue card.
    static func continueAccepts(_ id: String, isPlaylist: Bool = false,
                                markedForm: ProgressMark.StartedForm? = nil) -> Bool {
        if isPlaylist { return true }
        return !MediaFamily.isMusicByForm(id, markedForm: markedForm)
    }

    /// Newest-first, de-duplicated by id, capped. An id appearing in several
    /// sources keeps its most recent timestamp. Used for "Weiterhören" (by last
    /// played) and "Neu" (by added time).
    /// One clock for every source of a listening moment. The stores stamp
    /// in milliseconds; a server or a seed may hand over seconds. A row that
    /// ranks the two unnormalized would put every seconds entry last.
    static func normalizedMs(_ moment: Double) -> Double {
        guard moment > 0 else { return 0 }
        return moment < 100_000_000_000 ? moment * 1000 : moment
    }

    /// The ONE moment of an episode, for the row that ranks it and the card
    /// that names it: the newer of the local stand and the server stand,
    /// both on the ms clock. Two clocks at one tile put a title heard eight
    /// minutes ago on the other device behind one heard three hours ago.
    static func lastPlayedMs(local: Double, server: Double) -> Double {
        max(normalizedMs(local), normalizedMs(server))
    }

    static func byRecency(_ sources: [[(id: String, ts: Double)]], limit: Int) -> [String] {
        var best: [String: Double] = [:]
        for source in sources {
            for pair in source {
                best[pair.id] = max(best[pair.id] ?? -.greatestFiniteMagnitude, pair.ts)
            }
        }
        return best.sorted { lhs, rhs in
            lhs.value != rhs.value ? lhs.value > rhs.value : lhs.key < rhs.key
        }
        .prefix(limit)
        .map(\.key)
    }

    /// Cap ONE group's share of an already-ranked row. Music
    /// entries (albums+playlists) accrue progress far more often than books/
    /// episodes and would dominate the Continue row. The newest `cap` capped
    /// ids stay, the freed slots go to the others by recency. EXCEPTION
    /// (explicit): a row containing ONLY capped ids keeps them all. An
    /// emptier row would be worse than a music-heavy one.
    static func cappedShare(_ ranked: [String], capped: Set<String>,
                            cap: Int, limit: Int) -> [String] {
        let hasOthers = ranked.contains { !capped.contains($0) }
        var cappedCount = 0
        var out: [String] = []
        for id in ranked {
            if hasOthers, capped.contains(id) {
                guard cappedCount < cap else { continue }
                cappedCount += 1
            }
            out.append(id)
            if out.count == limit { break }
        }
        return out
    }

    /// Fair round-robin merge of several already-ordered id lists, capped. Each
    /// source keeps its order and the sources alternate, so no single source
    /// starves the others. A pure recency sort let a music library with fresher
    /// timestamps take every slot ("Recently Added" showed only music). Used for
    /// "Recently Added" (books + albums).
    /// Generic: the catalog mix rows (podcast tab + start) interleave typed
    /// tiles through the SAME merge. One implementation.
    static func interleave<T>(_ sources: [[T]], limit: Int) -> [T] {
        var result: [T] = []
        var index = 0
        var progressed = true
        while progressed && result.count < limit {
            progressed = false
            for source in sources where index < source.count {
                result.append(source[index])
                progressed = true
                if result.count >= limit { break }
            }
            index += 1
        }
        return result
    }
}
