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

    // MARK: - S19b: coverage validation + track fallback

    /// Do the validated chapters actually cover the book? ABS ships items whose
    /// chapters stop early (coverage 7–83% seen) while the tracks + total
    /// duration are correct. Unreliable when empty, or the last chapter ENDS
    /// before 90% of the book.
    /// NOTE: uses the last chapter's END (= actual coverage), not its START as
    /// first sketched — START misclassifies legit books with few long chapters
    /// (e.g. 2 chapters of 50% each cover the whole book but start at 50%).
    static func coversBook(_ validated: [ABSChapter], duration: Double) -> Bool {
        guard duration > 0, let last = validated.last else { return false }
        return last.end / duration >= 0.9
    }

    /// The chapter list to actually USE for navigation + display, and whether it
    /// is a track/rest fallback (→ the selector shows a discreet hint):
    /// - reliable chapters → use them.
    /// - multi-track otherwise → one chapter per track (track offsets are correct).
    /// - single file otherwise → the valid chapters + a "remaining" marker.
    static func resolved(chapters raw: [ABSChapter], tracks: [ABSAudioTrack], duration: Double)
        -> (chapters: [ABSChapter], isFallback: Bool) {
        let valid = validated(raw, duration: duration)
        if coversBook(valid, duration: duration) { return (valid, false) }
        if tracks.count > 1 { return (trackChapters(tracks, duration: duration), true) }
        return (withRestMarker(valid, duration: duration), true)
    }

    /// One chapter per track, using the correct per-track offsets (TrackMath).
    static func trackChapters(_ tracks: [ABSAudioTrack], duration: Double) -> [ABSChapter] {
        tracks.indices.map { i in
            let start = TrackMath.trackStart(index: i, tracks: tracks, bookDuration: duration)
            let end = i + 1 < tracks.count
                ? TrackMath.trackStart(index: i + 1, tracks: tracks, bookDuration: duration)
                : duration
            return ABSChapter(id: i, start: start, end: max(end, start + 1),
                              title: String(localized: "Track \(i + 1)"))
        }
    }

    /// Keep the valid chapters and append a "remaining" marker from the last end
    /// to the book end, so a single-file book with partial chapters still lets
    /// you jump into the un-chaptered tail.
    static func withRestMarker(_ valid: [ABSChapter], duration: Double) -> [ABSChapter] {
        let lastEnd = valid.last?.end ?? 0
        guard duration > lastEnd + 1 else { return valid }
        let rest = ABSChapter(id: (valid.last?.id ?? -1) + 1, start: lastEnd, end: duration,
                              title: String(localized: "Remaining"))
        return valid + [rest]
    }
}
