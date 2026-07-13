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
    let error: SubsonicAPIError?
    let albumList2: SubsonicAlbumList?
    let album: SubsonicAlbum?           // getAlbum (album with songs)
    let artists: SubsonicArtistsIndex?  // getArtists
    let artist: SubsonicArtist?         // getArtist (artist with albums)
    let searchResult3: SubsonicSearchResult3?
    let playlists: SubsonicPlaylists?
    let playlist: SubsonicPlaylist?     // getPlaylist (playlist with entries)
    let starred2: SubsonicStarred2?     // getStarred2
}

/// Starred (favorited) content — used for the album favorite state.
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
    let song: [SubsonicSong]?
}

nonisolated struct SubsonicSong: Decodable, Identifiable {
    let id: String
    let title: String?
    let album: String?
    let artist: String?
    let track: Int?
    let discNumber: Int?
    let duration: Int?
    let coverArt: String?
    let size: Int64?
    let suffix: String?
    let contentType: String?
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
    let entry: [SubsonicSong]?   // getPlaylist
}
