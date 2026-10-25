// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation

/// The ONE derivation for the "now playing" subtitle, shared by the
/// lock-screen NowPlaying, CarPlay (same MPNowPlayingInfoCenter) and the Live
/// Activity. Product decision: the TITLE is always the work
/// (book / episode / song); the current chapter appears only in the subtitle,
/// and a FALLBACK marker ("Part N of M", "from 3:15") NEVER does.
nonisolated enum NowPlayingPresentation {
    /// The LARGE now-playing title. The WORK. For music the SONG title (a
    /// song is the work being played, not its album); otherwise the book /
    /// episode title. NEVER empty: it falls back to a generic label so the
    /// player's title line can never go blank. (The cleaned chapter names do
    /// not carry the work title, so without this the full player's title
    /// would be empty.) Shared by the
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

    /// What the playing song of a music entry carries to every surface
    /// (mini player, full player, lock screen, CarPlay).
    struct Song: Equatable {
        /// The song's own artist, else the entry's; nil when neither names one.
        var artist: String?
        /// The cover-art id to show instead of the entry's cover; nil keeps
        /// the entry's cover.
        var coverArt: String?
    }

    /// The ONE answer which artist and which cover the playing song of a
    /// music entry shows. The artist is the song's, else the entry's (an
    /// album's artist; a playlist names none). The cover is the song's own
    /// inside a playlist, whose own cover is not the song's; an album and a
    /// single song keep the entry's cover, the one a download keeps.
    static func song(kind: MusicItemKind?, songArtist: String?, songCoverArt: String?,
                     entryArtist: String?) -> Song {
        Song(artist: nonEmpty(songArtist) ?? nonEmpty(entryArtist),
             coverArt: kind == .playlist ? nonEmpty(songCoverArt) : nil)
    }

    private static func nonEmpty(_ s: String?) -> String? {
        guard let s, !s.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        return s
    }
}
