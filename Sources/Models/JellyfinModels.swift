// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation

// Jellyfin wire DTOs (Etappe 2). Internal to the Jellyfin client/provider
// boundary, exactly like the `Subsonic*` Decodables. Jellyfin JSON is
// PascalCase; CodingKeys map to Swift names. Only the fields the provider
// maps into the domain types.

nonisolated struct JFAuthResponse: Decodable {
    let accessToken: String?
    let user: JFUser?
    enum CodingKeys: String, CodingKey {
        case accessToken = "AccessToken"
        case user = "User"
    }
}

nonisolated struct JFUser: Decodable {
    let id: String
    enum CodingKeys: String, CodingKey { case id = "Id" }
}

nonisolated struct JFItemsResult: Decodable {
    let items: [JFItem]?
    let totalRecordCount: Int?
    enum CodingKeys: String, CodingKey {
        case items = "Items"
        case totalRecordCount = "TotalRecordCount"
    }
}

nonisolated struct JFItem: Decodable {
    let id: String
    let name: String?
    let type: String?             // "MusicAlbum" | "Audio" | "MusicArtist" | "Playlist" | "AudioBook"
    /// The library's kind, on a `/Views` entry. "books" is what the
    /// audiobook path looks for.
    let collectionType: String?
    /// 100-ns ticks (Jellyfin's duration unit). Divide by 10_000_000 for seconds.
    let runTimeTicks: Double?
    let indexNumber: Int?
    let productionYear: Int?
    let genres: [String]?
    let album: String?
    let albumId: String?
    let albumArtist: String?
    let artists: [String]?
    let overview: String?
    let dateCreated: String?      // ISO-8601
    let childCount: Int?
    let userData: JFUserData?
    /// Entry id WITHIN a playlist (removal is addressed by this, not the song id).
    let playlistItemId: String?
    /// The folder an item sits in. The audiobook fold groups the
    /// `AudioBook` files of one folder into one book by this.
    let parentId: String?
    enum CodingKeys: String, CodingKey {
        case id = "Id", name = "Name", type = "Type"
        case collectionType = "CollectionType"
        case runTimeTicks = "RunTimeTicks", indexNumber = "IndexNumber"
        case productionYear = "ProductionYear", genres = "Genres"
        case album = "Album", albumId = "AlbumId", albumArtist = "AlbumArtist"
        case artists = "Artists", overview = "Overview"
        case dateCreated = "DateCreated", childCount = "ChildCount"
        case userData = "UserData"
        case playlistItemId = "PlaylistItemId"
        case parentId = "ParentId"
    }
}

nonisolated struct JFUserData: Decodable {
    let isFavorite: Bool?
    let playCount: Int?
    /// The listening position, in 100-ns ticks. MEASURED as the one
    /// road that carries: the session route (`/Sessions/Playing…`) read back
    /// as 0, this one read back identical.
    let playbackPositionTicks: Double?
    let played: Bool?
    enum CodingKeys: String, CodingKey {
        case isFavorite = "IsFavorite"
        case playCount = "PlayCount"
        case playbackPositionTicks = "PlaybackPositionTicks"
        case played = "Played"
    }
}

nonisolated struct JFCreatedPlaylist: Decodable {
    let id: String?
    enum CodingKeys: String, CodingKey { case id = "Id" }
}

nonisolated struct JFLyricsResponse: Decodable {
    let metadata: JFLyricsMetadata?
    let lyrics: [JFLyricLine]?
    enum CodingKeys: String, CodingKey {
        case metadata = "Metadata"
        case lyrics = "Lyrics"
    }
}

nonisolated struct JFLyricsMetadata: Decodable {
    let isSynced: Bool?
    enum CodingKeys: String, CodingKey { case isSynced = "IsSynced" }
}

nonisolated struct JFLyricLine: Decodable {
    /// Start in 100-ns ticks (synced lyrics only).
    let start: Double?
    let text: String?
    enum CodingKeys: String, CodingKey { case start = "Start", text = "Text" }
}
