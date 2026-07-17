import Foundation

/// Pure, testable ranking for the Home aggregation tab (Etappe 3). The Home tab
/// is a cross-section of the media libraries; its sections rank STRICTLY by
/// timestamp (no heuristics). This core merges id/timestamp pairs from several
/// sources; the view resolves the ids back to items via AppSession.
nonisolated enum HomeSections {
    /// Newest-first, de-duplicated by id, capped. An id appearing in several
    /// sources keeps its most recent timestamp. Used for "Weiterhören" (by last
    /// played) and "Neu" (by added time).
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

    /// Fair round-robin merge of several already-ordered id lists, capped. Each
    /// source keeps its order and the sources alternate, so no single source
    /// starves the others — a pure recency sort let a music library with fresher
    /// timestamps take every slot ("Recently Added" showed only music). Used for
    /// "Recently Added" (books + albums).
    static func interleave(_ sources: [[String]], limit: Int) -> [String] {
        var result: [String] = []
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
