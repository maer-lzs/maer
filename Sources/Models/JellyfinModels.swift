// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

// Jellyfin wire DTOs (Etappe 2) — internal to the Jellyfin client/provider
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
    let type: String?             // "MusicAlbum" | "Audio" | "MusicArtist" | "Playlist"
    /// 100-ns ticks (Jellyfin's duration unit) — divide by 10_000_000 for seconds.
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
    enum CodingKeys: String, CodingKey {
        case id = "Id", name = "Name", type = "Type"
        case runTimeTicks = "RunTimeTicks", indexNumber = "IndexNumber"
        case productionYear = "ProductionYear", genres = "Genres"
        case album = "Album", albumId = "AlbumId", albumArtist = "AlbumArtist"
        case artists = "Artists", overview = "Overview"
        case dateCreated = "DateCreated", childCount = "ChildCount"
        case userData = "UserData"
    }
}

nonisolated struct JFUserData: Decodable {
    let isFavorite: Bool?
    let playCount: Int?
    enum CodingKeys: String, CodingKey {
        case isFavorite = "IsFavorite"
        case playCount = "PlayCount"
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
