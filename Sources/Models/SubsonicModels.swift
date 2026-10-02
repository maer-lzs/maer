// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation

/// Subsonic API responses are wrapped in a `"subsonic-response"` object; every
/// endpoint returns a subset of the fields here (all optional). We decode one
/// flexible body instead of a generic per-endpoint envelope.
nonisolated struct SubsonicEnvelope: Decodable {
    let subsonicResponse: SubsonicBody
    enum CodingKeys: String, CodingKey { case subsonicResponse = "subsonic-response" }
}

nonisolated struct SubsonicBody: Decodable {
    let status: String?
    let version: String?
    /// The server's own name for itself (OpenSubsonic), e.g. "navidrome".
    let type: String?
    /// The server's own version (OpenSubsonic), e.g. "0.64.2 (38dc2727)".
    let serverVersion: String?
    let error: SubsonicAPIError?
    let albumList2: SubsonicAlbumList?
    let album: SubsonicAlbum?           // getAlbum (album with songs)
    let artists: SubsonicArtistsIndex?  // getArtists
    let artist: SubsonicArtist?         // getArtist (artist with albums)
    let searchResult3: SubsonicSearchResult3?
    let playlists: SubsonicPlaylists?
    let playlist: SubsonicPlaylist?     // getPlaylist (playlist with entries)
    let starred2: SubsonicStarred2?     // getStarred2
    let artistInfo2: SubsonicArtistInfo?    // getArtistInfo2
    let albumInfo: SubsonicAlbumInfo?       // getAlbumInfo2
    let topSongs: SubsonicTopSongs?         // getTopSongs
    let lyricsList: SubsonicLyricsList?     // getLyricsBySongId (OpenSubsonic)
    let song: SubsonicSong?                 // getSong
    let randomSongs: SubsonicRandomSongs?   // getRandomSongs (whole-library shuffle)
    let bookmarks: SubsonicBookmarks?       // getBookmarks (playlist continue-listening)
    let genres: SubsonicGenres?             // getGenres
    let songsByGenre: SubsonicSongsByGenre? // getSongsByGenre
    let musicFolders: SubsonicMusicFolders? // getMusicFolders
    let openSubsonicExtensions: [SubsonicSignIn.Extension]? // getOpenSubsonicExtensions
    let scanStatus: SubsonicScanStatus?     // getScanStatus
}

/// getScanStatus. `count` is the number of songs the server holds and
/// `lastScan` (Navidrome) when it last looked at its folders; together they
/// say whether anything can have changed since the song list was taken.
nonisolated struct SubsonicScanStatus: Decodable {
    let count: Int?
    let lastScan: String?
}

/// getMusicFolders. The top-level folders a server is configured with. This
/// is the ONE level a Subsonic server separates its stock on, so it is the
/// level on which "this half is music, that half is audiobooks" can be
/// answered without guessing. The id arrives as a number in the JSON but
/// travels as a string everywhere else (query param, stored assignment).
nonisolated struct SubsonicMusicFolders: Decodable {
    let musicFolder: [SubsonicMusicFolder]?
}
nonisolated struct SubsonicMusicFolder: Decodable {
    let id: SubsonicFolderID?
    let name: String?
}

/// Servers disagree on whether the folder id is a number or a string; both
/// forms appear in the wild, and a decoding failure here would present as
/// "your server has no folders".
nonisolated struct SubsonicFolderID: Decodable {
    let value: String

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let int = try? container.decode(Int.self) { value = String(int) }
        else { value = try container.decode(String.self) }
    }
}

// GetGenres. The genre NAME arrives as the element content, which the
// Subsonic JSON serialization ships under the "value" key.
nonisolated struct SubsonicGenres: Decodable {
    let genre: [SubsonicGenre]?
}
nonisolated struct SubsonicGenre: Decodable {
    let value: String?
    let songCount: Int?
    let albumCount: Int?
}
nonisolated struct SubsonicSongsByGenre: Decodable {
    let song: [SubsonicSong]?
}

// MARK: - OpenSubsonic metadata. Empty fields are NORMAL. A server
// without configured agents returns nothing; UI sections appear only with
// content, never as errors.

nonisolated struct SubsonicArtistInfo: Decodable {
    let biography: String?
    let musicBrainzId: String?
    let smallImageUrl: String?
    let mediumImageUrl: String?
    let largeImageUrl: String?
    let similarArtist: [SubsonicArtist]?
}

nonisolated struct SubsonicAlbumInfo: Decodable {
    let notes: String?
    let musicBrainzId: String?
    let smallImageUrl: String?
    let mediumImageUrl: String?
    let largeImageUrl: String?
}

nonisolated struct SubsonicTopSongs: Decodable {
    let song: [SubsonicSong]?
}

nonisolated struct SubsonicRandomSongs: Decodable {
    let song: [SubsonicSong]?
}

nonisolated struct SubsonicBookmarks: Decodable {
    let bookmark: [SubsonicBookmark]?
}

/// A Subsonic play-position bookmark: a song (`entry`) + a position in ms + an
/// optional `comment` (Mär stores the enclosing playlist item id there. A song
/// can be in several playlists, but a bookmark only knows song+position).
nonisolated struct SubsonicBookmark: Decodable {
    let position: Int?          // milliseconds into the song
    let comment: String?
    let created: String?        // ISO-8601
    let changed: String?        // ISO-8601 (most-recent wins)
    let entry: SubsonicSong?
}

/// OpenSubsonic structured lyrics: optionally time-synced lines.
nonisolated struct SubsonicLyricsList: Decodable {
    let structuredLyrics: [SubsonicStructuredLyrics]?
}

nonisolated struct SubsonicStructuredLyrics: Decodable {
    let lang: String?
    let synced: Bool?
    let offset: Double?          // global offset in ms
    let displayArtist: String?
    let displayTitle: String?
    let line: [SubsonicLyricsLine]?
}

nonisolated struct SubsonicLyricsLine: Decodable {
    let start: Double?           // ms from song start (synced only)
    let value: String
}

/// Starred (favorited) content. Used for the album favorite state.
nonisolated struct SubsonicStarred2: Decodable {
    let album: [SubsonicAlbum]?
    let song: [SubsonicSong]?
    let artist: [SubsonicArtist]?
}

nonisolated struct SubsonicAPIError: Decodable {
    let code: Int
    let message: String?
}

nonisolated struct SubsonicAlbumList: Decodable {
    let album: [SubsonicAlbum]?
}

/// Funkwhale compat: ids arrive as NUMBER there, as string on
/// Navidrome & co. ONE shared decode accepts both and yields a
/// String. The known ecosystem quirk, not Funkwhale-exclusive.
extension KeyedDecodingContainer {
    nonisolated func lenientID(forKey key: Key) throws -> String {
        if let s = try? decode(String.self, forKey: key) { return s }
        if let i = try? decode(Int.self, forKey: key) { return String(i) }
        throw DecodingError.typeMismatch(String.self, .init(
            codingPath: codingPath + [key],
            debugDescription: "id is neither string nor int"))
    }

    /// The optional form of the same rule, for every id-like field that
    /// may be absent. Measured on Funkwhale 1.2.10: `artistId` arrives as
    /// a number, and a strict String decode threw away the whole album.
    nonisolated func lenientIDIfPresent(forKey key: Key) throws -> String? {
        guard contains(key), try !decodeNil(forKey: key) else { return nil }
        return try lenientID(forKey: key)
    }
}

/// An album. `getAlbumList2` returns it without `song`; `getAlbum` includes the
/// track list in `song`.
nonisolated struct SubsonicAlbum: Decodable, Identifiable {
    let id: String
    let name: String?
    let artist: String?
    let artistId: String?
    let coverArt: String?
    let songCount: Int?
    let duration: Int?
    let year: Int?
    let genre: String?
    let created: String?
    /// OpenSubsonic: release MBID. Key into the Cover Art Archive.
    let musicBrainzId: String?
    let song: [SubsonicSong]?

    enum CodingKeys: String, CodingKey {
        case id, name, artist, artistId, coverArt, songCount, duration, year,
             genre, created, musicBrainzId, song
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.lenientID(forKey: .id)
        name = try c.decodeIfPresent(String.self, forKey: .name)
        artist = try c.decodeIfPresent(String.self, forKey: .artist)
        artistId = try c.lenientIDIfPresent(forKey: .artistId)
        coverArt = try c.decodeIfPresent(String.self, forKey: .coverArt)
        songCount = try c.decodeIfPresent(Int.self, forKey: .songCount)
        duration = try c.decodeIfPresent(Int.self, forKey: .duration)
        year = try c.decodeIfPresent(Int.self, forKey: .year)
        genre = try c.decodeIfPresent(String.self, forKey: .genre)
        created = try c.decodeIfPresent(String.self, forKey: .created)
        musicBrainzId = try c.decodeIfPresent(String.self, forKey: .musicBrainzId)
        song = try c.decodeIfPresent([SubsonicSong].self, forKey: .song)
    }
    init(id: String, name: String?, artist: String?, artistId: String?,
         coverArt: String?, songCount: Int?, duration: Int?, year: Int?,
         genre: String?, created: String?, musicBrainzId: String?, song: [SubsonicSong]?) {
        self.id = id; self.name = name; self.artist = artist; self.artistId = artistId
        self.coverArt = coverArt; self.songCount = songCount; self.duration = duration
        self.year = year; self.genre = genre; self.created = created
        self.musicBrainzId = musicBrainzId; self.song = song
    }
}

nonisolated struct SubsonicSong: Decodable, Identifiable {
    let id: String
    let title: String?
    let album: String?
    /// Album key for mosaic dedupe (Korrektur 01.08): per-SONG coverArt ids
    /// (Navidrome `mf-…`) defeat cover-id dedupe. The album is the identity.
    let albumId: String?
    let artist: String?
    let track: Int?
    let discNumber: Int?
    let duration: Int?
    let coverArt: String?
    let size: Int64?
    let suffix: String?
    let contentType: String?
    /// Play count (OpenSubsonic/Navidrome). Basis for the client-side
    /// "Top Songs" ranking on album/playlist pages. nil on plain servers.
    let playCount: Int?
    /// When the server added the song, and when this user last played it
    /// (ISO 8601, both OpenSubsonic/Navidrome). The song list sorts by them.
    let created: String?
    let played: String?

    enum CodingKeys: String, CodingKey {
        case id, title, album, albumId, artist, track, discNumber, duration, coverArt,
             size, suffix, contentType, playCount, created, played
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.lenientID(forKey: .id)
        title = try c.decodeIfPresent(String.self, forKey: .title)
        album = try c.decodeIfPresent(String.self, forKey: .album)
        albumId = c.contains(.albumId) ? try? c.lenientID(forKey: .albumId) : nil
        artist = try c.decodeIfPresent(String.self, forKey: .artist)
        track = try c.decodeIfPresent(Int.self, forKey: .track)
        discNumber = try c.decodeIfPresent(Int.self, forKey: .discNumber)
        duration = try c.decodeIfPresent(Int.self, forKey: .duration)
        coverArt = try c.decodeIfPresent(String.self, forKey: .coverArt)
        size = try c.decodeIfPresent(Int64.self, forKey: .size)
        suffix = try c.decodeIfPresent(String.self, forKey: .suffix)
        contentType = try c.decodeIfPresent(String.self, forKey: .contentType)
        playCount = try c.decodeIfPresent(Int.self, forKey: .playCount)
        created = try c.decodeIfPresent(String.self, forKey: .created)
        played = try c.decodeIfPresent(String.self, forKey: .played)
    }
}

nonisolated struct SubsonicArtistsIndex: Decodable {
    let index: [SubsonicArtistIndexEntry]?
}

nonisolated struct SubsonicArtistIndexEntry: Decodable {
    let name: String?
    let artist: [SubsonicArtist]?
}

nonisolated struct SubsonicArtist: Decodable, Identifiable {
    let id: String
    let name: String?
    let coverArt: String?
    let albumCount: Int?
    let album: [SubsonicAlbum]?   // getArtist

    enum CodingKeys: String, CodingKey { case id, name, coverArt, albumCount, album }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.lenientID(forKey: .id)
        name = try c.decodeIfPresent(String.self, forKey: .name)
        coverArt = try c.decodeIfPresent(String.self, forKey: .coverArt)
        albumCount = try c.decodeIfPresent(Int.self, forKey: .albumCount)
        album = try c.decodeIfPresent([SubsonicAlbum].self, forKey: .album)
    }
    init(id: String, name: String?, coverArt: String?, albumCount: Int?, album: [SubsonicAlbum]?) {
        self.id = id; self.name = name; self.coverArt = coverArt
        self.albumCount = albumCount; self.album = album
    }
}

nonisolated struct SubsonicSearchResult3: Decodable {
    let artist: [SubsonicArtist]?
    let album: [SubsonicAlbum]?
    let song: [SubsonicSong]?
}

nonisolated struct SubsonicPlaylists: Decodable {
    let playlist: [SubsonicPlaylist]?
}

nonisolated struct SubsonicPlaylist: Decodable, Identifiable {
    let id: String
    let name: String?
    let songCount: Int?
    let duration: Int?
    let coverArt: String?
    let owner: String?
    /// ISO-8601 last-modified timestamp. The playlist cards sort "recently changed first".
    let changed: String?
    let entry: [SubsonicSong]?   // getPlaylist

    enum CodingKeys: String, CodingKey {
        case id, name, songCount, duration, coverArt, owner, changed, entry
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.lenientID(forKey: .id)
        name = try c.decodeIfPresent(String.self, forKey: .name)
        songCount = try c.decodeIfPresent(Int.self, forKey: .songCount)
        duration = try c.decodeIfPresent(Int.self, forKey: .duration)
        coverArt = try c.decodeIfPresent(String.self, forKey: .coverArt)
        owner = try c.decodeIfPresent(String.self, forKey: .owner)
        changed = try c.decodeIfPresent(String.self, forKey: .changed)
        entry = try c.decodeIfPresent([SubsonicSong].self, forKey: .entry)
    }
    init(id: String, name: String?, songCount: Int?, duration: Int?,
         coverArt: String?, owner: String?, changed: String?, entry: [SubsonicSong]?) {
        self.id = id; self.name = name; self.songCount = songCount; self.duration = duration
        self.coverArt = coverArt; self.owner = owner; self.changed = changed; self.entry = entry
    }
}
