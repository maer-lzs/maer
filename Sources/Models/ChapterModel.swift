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
    /// - Parameter isPodcast: podcast episodes legitimately ship PARTIAL chapter
    ///   coverage (segment markers) — the < 90 % coverage heuristic must NOT
    ///   apply. Show the valid chapters as-is: no rest marker, no track fallback;
    ///   past the last chapter the player simply shows no chapter line. The
    ///   coverage fallback stays audiobook-only (T9b).
    static func resolved(chapters raw: [ABSChapter], tracks: [ABSAudioTrack], duration: Double,
                         isPodcast: Bool = false)
        -> (chapters: [ABSChapter], isFallback: Bool) {
        let valid = validated(raw, duration: duration)
        if isPodcast { return (valid, false) }
        if coversBook(valid, duration: duration) { return (valid, false) }
        if tracks.count > 1 { return (trackChapters(tracks, duration: duration), true) }
        return (withTimeMarks(valid, duration: duration), true)
    }

    /// One chapter per track, using the correct per-track offsets (TrackMath).
    /// T9d: real coverage is often only a fraction (the operator: Schattensaat 24 %,
    /// Kriegswirren 36 %), so these are NOT chapters — name them "Part N of M"
    /// so they don't masquerade as a book's real chapters.
    static func trackChapters(_ tracks: [ABSAudioTrack], duration: Double) -> [ABSChapter] {
        let count = tracks.count
        return tracks.indices.map { i in
            let start = TrackMath.trackStart(index: i, tracks: tracks, bookDuration: duration)
            let end = i + 1 < tracks.count
                ? TrackMath.trackStart(index: i + 1, tracks: tracks, bookDuration: duration)
                : duration
            return ABSChapter(id: i, start: start, end: max(end, start + 1),
                              title: String(localized: "Part \(i + 1) of \(count)"))
        }
    }

    /// Single-file m4b with partial chapters: keep the real chapters, then cover
    /// the un-chaptered tail with jump marks every 15 minutes, named by their
    /// start time ("from 3:15", "from 3:30" …). T9d: better than one 5–6 h
    /// "remaining" lump when coverage stops early.
    static func withTimeMarks(_ valid: [ABSChapter], duration: Double) -> [ABSChapter] {
        let lastEnd = valid.last?.end ?? 0
        guard duration > lastEnd + 1 else { return valid }
        let step = 900.0   // 15 minutes
        var marks: [ABSChapter] = []
        var start = lastEnd
        var id = (valid.last?.id ?? -1) + 1
        while start < duration - 1 {
            let end = min(start + step, duration)
            marks.append(ABSChapter(id: id, start: start, end: end,
                                    title: String(localized: "from \(timeLabel(start))")))
            start = end
            id += 1
        }
        return valid + marks
    }

    /// Compact h:mm:ss / m:ss label for a position in seconds.
    static func timeLabel(_ seconds: Double) -> String {
        let t = Int(max(0, seconds)); let h = t / 3600; let m = (t % 3600) / 60; let s = t % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }
}
