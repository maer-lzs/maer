// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation

/// T9c: the ONE derivation for the "now playing" subtitle, shared by the
/// lock-screen NowPlaying, CarPlay (same MPNowPlayingInfoCenter) and the Live
/// Activity. Product decision: the TITLE is always the work
/// (book / episode / song); the current chapter appears only in the subtitle,
/// and a FALLBACK marker ("Part N of M", "from 3:15") NEVER does.
nonisolated enum NowPlayingPresentation {
    /// The LARGE now-playing title. The WORK. For music the SONG title (a
    /// song is the work being played, not its album); otherwise the book /
    /// episode title. NEVER empty: it falls back to a generic label so the
    /// player's title line can never go blank. (Regression guard: the T9d
    /// chapter cleanup once left the full player's title empty because the work
    /// title had only ever lived INSIDE the raw chapter names, e.g. "Kapitel 71
    /// – Armageddon …"; the player had no title line of its own.) Shared by the
    /// full player and the lock screen / CarPlay.
    static func title(isMusic: Bool, songTitle: String?, workTitle: String?, fallback: String) -> String {
        if isMusic, let song = nonEmpty(songTitle) { return song }
        return nonEmpty(workTitle) ?? fallback
    }

    /// Subtitle line, e.g. "Chapter 2 · Andrea Wulf". The chapter is included
    /// only when it is a REAL chapter (not a fallback marker); author is appended
    /// when present. nil when there is nothing to show.
    static func subtitle(chapterTitle: String?, author: String?, isFallback: Bool) -> String? {
        let chapter = isFallback ? nil : nonEmpty(chapterTitle)
        let parts = [chapter, nonEmpty(author)].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// The lead of the mini player's second line, before the remaining
    /// time: the chapter for a book or an episode, the ARTIST for a song. A
    /// song's only "chapter" is the song itself, so the bar used to repeat
    /// the title under the title (measured on a device, 14.09.2026). nil
    /// when there is nothing to lead with; the remaining time stands alone.
    static func miniLead(isMusic: Bool, chapterTitle: String?, artist: String?) -> String? {
        if isMusic { return nonEmpty(artist) }
        return nonEmpty(chapterTitle)
    }

    private static func nonEmpty(_ s: String?) -> String? {
        guard let s, !s.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        return s
    }
}
