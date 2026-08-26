// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation

// Jellyfin stage 1½: the neutral music DOMAIN types the `MusicProvider`
// protocol speaks — in the spirit of `LibraryItem` (which already covers
// albums/songs as items). Only the fields the UI actually uses; the wire
// DTOs (`Subsonic*` Decodables) stay internal to their provider, which maps
// wire → domain at its boundary (anti-corruption layer).

/// An artist as the browse/search surfaces need it.
nonisolated struct MusicArtist: Identifiable, Hashable {
    let id: String
    /// Nil when the server sent none — call sites keep their own localized
    /// fallbacks ("Unknown Artist" on the artist page, "—" in the deck).
    let name: String?
    let albumCount: Int?
}

/// The ONE decision "which artist image does a surface
/// render" — pure, so every surface (list row, portrait strip, artist page
/// header) answers it identically and the answer is testable instead of
/// re-derived per view. The opt-out `musicArtistImagesOnline` governs the
/// OPEN-SOURCE chain (MusicBrainz→Wikidata→Commons); an image the library
/// server itself hands out is a library fact and stays — the toggle's own
/// wording names the web services, not the server.
nonisolated enum ArtistImagePolicy {
    enum Source: String {
        case server, web, none
    }

    /// `webURL` = the chain's result (nil when it found nothing or was off).
    static func source(serverImageURL: URL?, webImageURL: URL?, webEnabled: Bool) -> Source {
        if serverImageURL != nil { return .server }
        return (webEnabled && webImageURL != nil) ? .web : .none
    }

    static func rendered(serverImageURL: URL?, webImageURL: URL?, webEnabled: Bool) -> URL? {
        switch source(serverImageURL: serverImageURL, webImageURL: webImageURL, webEnabled: webEnabled) {
        case .server: return serverImageURL
        case .web: return webImageURL
        case .none: return nil
        }
    }
}

/// A playlist row/card. `changedAt` is epoch ms (parsed at the provider
/// boundary), so the F5 "recently changed first" sort needs no wire format.
nonisolated struct MusicPlaylist: Identifiable, Hashable {
    let id: String
    let name: String?
    let songCount: Int?
    /// Total duration in seconds.
    let duration: Double?
    let changedAt: Double?
}

/// Optional artist metadata (OpenSubsonic `getArtistInfo2` today). Empty is
/// NORMAL — a provider without metadata agents (or without the capability)
/// returns nil/empty and the UI sections simply don't appear.
nonisolated struct MusicArtistInfo {
    let biography: String?
    /// The one image the UI renders (providers pick their best size).
    let imageURL: URL?
    /// Names only — the UI matches them against the own library's artists.
    let similarArtistNames: [String]
    /// Feeds the no-key portrait chain (MB→Wikidata→Commons) directly.
    let musicBrainzId: String?
}

/// Optional album metadata (notes + MusicBrainz id for the CAA cover).
nonisolated struct MusicAlbumInfo {
    let notes: String?
    let musicBrainzId: String?
}

/// One top-song row of an artist: the playable item plus the album name the
/// row shows (the item itself carries title/artist).
nonisolated struct MusicTopSong: Identifiable {
    var id: String { item.id }
    let item: LibraryItem
    let albumName: String?
}


/// Provider-neutral album-shelf vocabulary — the LAST Subsonic semantic in
/// the protocol is gone: providers translate this enum into their own sort
/// (Subsonic getAlbumList2 types, Jellyfin SortBy/SortOrder).
nonisolated enum MusicShelf: Hashable {
    case newest, frequent, recent, byArtist, alphabetical
}

/// M6 (pure, tested): client-side "Top Songs" ranking over the play counts
/// a detail fetch already carries — NO extra server request. Only counts > 0
/// rank; ties keep track order; an all-nil/zero list yields [] (the section
/// then disappears silently — honest capability behaviour on plain servers).
nonisolated enum MusicPopularity {
    static func topIndices(playCounts: [Int?], limit: Int = 5) -> [Int] {
        let ranked = playCounts.enumerated()
            .compactMap { idx, count -> (index: Int, count: Int)? in
                guard let count, count > 0 else { return nil }
                return (idx, count)
            }
            .sorted { $0.count != $1.count ? $0.count > $1.count : $0.index < $1.index }
        return ranked.prefix(limit).map(\.index)
    }
}

/// Shared pure assembly of a multi-song music item's player material: songs →
/// per-song tracks (stream id in `contentUrl`) plus one chapter per song, so
/// "next chapter" = "next song" — both music providers build their
/// albums/playlists through this.
nonisolated enum MusicTrackAssembly {
    struct Song {
        let id: String
        let title: String?
        let duration: Double
        let size: Int64?
    }

    static func build(_ songs: [Song])
        -> (tracks: [ABSAudioTrack], chapters: [ABSChapter], total: Double) {
        var tracks: [ABSAudioTrack] = []
        var chapters: [ABSChapter] = []
        var offset = 0.0
        for (i, song) in songs.enumerated() {
            tracks.append(ABSAudioTrack(
                index: i, startOffset: offset, duration: song.duration,
                contentUrl: song.id, metadata: ABSFileMetadata(size: song.size)
            ))
            chapters.append(ABSChapter(
                id: i, start: offset, end: offset + song.duration,
                title: song.title ?? String(localized: "Track \(i + 1)")
            ))
            offset += song.duration
        }
        return (tracks, chapters, offset)
    }
}

/// One music genre as the providers report it. Counts are optional —
/// Subsonic ships song+album counts, Jellyfin ships none (the page then
/// sorts alphabetically and hides the numerals; honestly reported).
nonisolated struct MusicGenre: Equatable, Identifiable, Sendable {
    let name: String
    var songCount: Int? = nil
    var albumCount: Int? = nil
    var id: String { name }
}

/// M3 pure presentation rules (tested): empty names out; genres KNOWN to be
/// empty (both counts present and zero) out — unknown counts (Jellyfin) stay;
/// sort by album count desc, then song count desc, then name (so a count-less
/// list is simply alphabetical).
nonisolated enum MusicGenrePresentation {
    static func presented(_ raw: [MusicGenre]) -> [MusicGenre] {
        raw.filter { genre in
            let name = genre.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { return false }
            if let songs = genre.songCount, let albums = genre.albumCount,
               songs == 0, albums == 0 { return false }
            return true
        }
        .sorted { a, b in
            let aKey = (a.albumCount ?? 0, a.songCount ?? 0)
            let bKey = (b.albumCount ?? 0, b.songCount ?? 0)
            if aKey == bKey {
                return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
            }
            return aKey > bKey
        }
    }
}

/// M3 glyphs: curated SF-symbol mapping for the common genres,
/// deterministic `music.note` fallback for the unknown — NEVER guess-and-be-
/// wrong. Matching is normalized (lowercase, diacritics stripped) exact
/// first, then whole-word (so "Progressive Rock" finds rock); the FIRST
/// matching word in the name wins (deterministic).
nonisolated enum MusicGenreGlyphs {
    private static let map: [String: String] = [
        "rock": "guitars", "punk": "guitars", "grunge": "guitars",
        "metal": "bolt", "hardrock": "bolt",
        "pop": "music.mic", "schlager": "music.mic",
        "jazz": "music.quarternote.3", "blues": "music.quarternote.3", "swing": "music.quarternote.3",
        "classical": "pianokeys", "klassik": "pianokeys", "piano": "pianokeys", "orchestral": "pianokeys",
        "electronic": "waveform", "electro": "waveform", "edm": "waveform",
        "techno": "waveform", "house": "waveform", "trance": "waveform", "dance": "waveform",
        "ambient": "moon.stars", "chillout": "moon.stars", "chill": "moon.stars", "lounge": "moon.stars",
        "hiphop": "headphones", "rap": "headphones",
        "soul": "sparkles", "funk": "sparkles", "rnb": "sparkles", "disco": "sparkles",
        "folk": "leaf", "country": "leaf", "acoustic": "leaf",
        "reggae": "sun.max",
        "soundtrack": "film", "score": "film", "filmmusik": "film",
        "audiobook": "book", "hoerbuch": "book", "hoerspiel": "book",
        // Diacritic folding yields "horbuch"/"horspiel" (ö→o, not ö→oe) —
        // both transliterations map.
        "horbuch": "book", "horspiel": "book",
        "podcast": "mic", "spoken": "mic", "speech": "mic",
        "world": "globe", "latin": "globe",
        "indie": "star", "alternative": "star",
        "christmas": "snowflake", "weihnachten": "snowflake", "holiday": "snowflake",
        "kids": "teddybear", "children": "teddybear", "kinder": "teddybear",
    ]

    /// Normalized key: lowercase, diacritics stripped, separators removed
    /// ("Hip-Hop" → "hiphop", "R&B" → "rb" — mapped via "rnb" word rule below).
    static func normalized(_ name: String) -> String {
        name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .lowercased()
            .filter { $0.isLetter || $0.isNumber }
    }

    static func symbol(for name: String) -> String {
        if let exact = map[normalized(name)] { return exact }
        // Whole words of the raw name, in order — first mapped word wins.
        let words = name.split { !$0.isLetter && !$0.isNumber }
        for word in words {
            if let hit = map[normalized(String(word))] { return hit }
        }
        return "music.note"
    }
}
