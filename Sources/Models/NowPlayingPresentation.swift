import Foundation

/// T9c: the ONE derivation for the "now playing" subtitle, shared by the
/// lock-screen NowPlaying, CarPlay (same MPNowPlayingInfoCenter) and the Live
/// Activity (Regel 2). Product decision: the TITLE is always the work
/// (book / episode / song); the current chapter appears only in the subtitle,
/// and a FALLBACK marker ("Part N of M", "from 3:15") NEVER does.
nonisolated enum NowPlayingPresentation {
    /// Subtitle line, e.g. "Chapter 2 · Andrea Wulf". The chapter is included
    /// only when it is a REAL chapter (not a fallback marker); author is appended
    /// when present. nil when there is nothing to show.
    static func subtitle(chapterTitle: String?, author: String?, isFallback: Bool) -> String? {
        let chapter = isFallback ? nil : nonEmpty(chapterTitle)
        let parts = [chapter, nonEmpty(author)].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private static func nonEmpty(_ s: String?) -> String? {
        guard let s, !s.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        return s
    }
}
