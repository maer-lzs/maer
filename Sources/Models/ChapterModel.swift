import Foundation

/// S19: pure, tested validation + lookup for chapter metadata. Some server
/// items ship BROKEN chapters (overlapping, out-of-range, zero-length). The
/// player must not derive a "current chapter" / "X min left in chapter" from
/// those and show nonsense that counts down to a non-existent end. Both the
/// player AND the chapter selector work off the SAME validated list, so what
/// the selector lists and what the player shows can never disagree.
nonisolated enum ChapterModel {
    /// Keep only trustworthy chapters: positive span (end > start), non-negative
    /// start, within the book duration (when known), and not overlapping a
    /// previously kept chapter. Result is ascending and non-overlapping.
    static func validated(_ raw: [ABSChapter], duration: Double) -> [ABSChapter] {
        let hasDuration = duration > 0
        var result: [ABSChapter] = []
        for ch in raw.sorted(by: { $0.start < $1.start }) {
            guard ch.end > ch.start, ch.start >= 0 else { continue }
            if hasDuration, ch.start >= duration || ch.end > duration + 1 { continue }
            if let last = result.last, ch.start < last.end { continue }   // overlaps previous
            result.append(ch)
        }
        return result
    }

    /// The chapter CONTAINING `time` in a validated list — nil when `time` falls
    /// in a gap or past the last chapter's end, so the caller omits the chapter
    /// display instead of showing a wrong one.
    static func current(at time: Double, in validated: [ABSChapter]) -> ABSChapter? {
        validated.last { time >= $0.start && time < $0.end }
    }
}
