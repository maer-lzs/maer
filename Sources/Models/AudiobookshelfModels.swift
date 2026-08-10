// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation

// MARK: - Authorisierung / Nutzer

nonisolated struct ABSUser: Decodable {
    let id: String
    let username: String
}

/// Response of POST /login. Older servers return the long-lived `token`, newer
/// ones (JWT auth from v2.26) an `accessToken` — both optional, the long-lived
/// one is preferred.
nonisolated struct LoginResponse: Decodable {
    let user: LoginUser
}

nonisolated struct LoginUser: Decodable {
    let token: String?
    let accessToken: String?
}

/// Response of /api/me — holds all of the user's progress entries.
nonisolated struct MeResponse: Decodable {
    let mediaProgress: [MediaProgressEntry]?
    let bookmarks: [ABSBookmark]?
}

/// Bookmark (stored server-side on the user). `time` is whole seconds and
/// doubles as the delete key.
nonisolated struct ABSBookmark: Codable, Identifiable, Equatable {
    let libraryItemId: String
    let title: String
    let time: Double
    let createdAt: Double?

    var id: String { "\(libraryItemId)-\(time)" }
}

/// A progress entry from /api/me. Mapped to books locally so the whole library
/// list can show indicators without a per-book request.
nonisolated struct MediaProgressEntry: Decodable {
    let libraryItemId: String
    /// Set only for podcast progress — identifies the episode.
    let episodeId: String?
    let currentTime: Double?
    let duration: Double?
    let progress: Double?
    let isFinished: Bool?
    let lastUpdate: Double?
}

/// Compact, view-friendly progress info for a book. Codable so it can be cached
/// alongside the book list for offline access.
nonisolated struct BookProgress: Equatable, Codable {
    let fraction: Double      // 0...1
    let isFinished: Bool
    let lastUpdate: Double    // ms since 1970, for "recently listened" sorting
    /// Absolute position in seconds — fallback to recompute fraction locally
    /// from the book duration when the server omits it (multi-file books with a
    /// missing server duration). Optional: old disk caches.
    var currentTime: Double? = nil

    var percentInt: Int { Int((fraction * 100).rounded()) }
    var isStarted: Bool { fraction > 0.001 && !isFinished }

    /// Remaining-time text ("3 h 12 min left") from the book duration — nil when
    /// no duration is known (then show percent as fallback).
    func remainingText(bookDuration: Double?) -> String? {
        guard let bookDuration, bookDuration > 0 else { return nil }
        let listened = currentTime ?? fraction * bookDuration
        let remaining = max(0, bookDuration - listened)
        let totalMinutes = Int(remaining) / 60
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60
        if hours > 0 { return String(localized: "\(hours) hr \(minutes) min left") }
        return String(localized: "\(minutes) min left")
    }
}

// MARK: - Libraries

nonisolated struct LibrariesResponse: Decodable {
    let libraries: [ABSLibrary]
}

nonisolated struct ABSLibrary: Decodable, Identifiable {
    let id: String
    let name: String
    /// "book" | "podcast" — distinguishes audiobook from podcast libraries.
    /// Default nil → existing memberwise-init callers (RSS/Local) stay valid.
    var mediaType: String? = nil
    /// Library folders (the list endpoint usually includes them) — target path
    /// for a newly created podcast subscription.
    var folders: [ABSFolder]? = nil

    var isPodcast: Bool { mediaType == "podcast" }
}

// MARK: - Podcast management (folders, feed metadata)

/// A library folder — target path for a newly created podcast subscription.
nonisolated struct ABSFolder: Decodable, Identifiable {
    let id: String
    let fullPath: String?
}

/// `GET /api/libraries/{id}` returns the library object DIRECTLY (folders at
/// the top level) — NOT wrapped in `{ library: … }`.
nonisolated struct LibraryWithFolders: Decodable {
    let folders: [ABSFolder]?
}

/// Response of POST /api/podcasts/feed — server-side parsed feed.
nonisolated struct PodcastFeedResponse: Decodable {
    let podcast: PodcastFeedData
}

nonisolated struct PodcastFeedData: Decodable {
    let metadata: PodcastFeedMetadata
}

nonisolated struct PodcastFeedMetadata: Decodable {
    let title: String?
    let author: String?
    let description: String?
    let imageUrl: String?
    let feedUrl: String?
}

// MARK: - Book list (list endpoint)

nonisolated struct LibraryItemsResponse: Decodable {
    let results: [LibraryItem]
    /// Total number of items in the library (server paging) — drives how many
    /// pages the progressive load still has to fetch.
    let total: Int?
}

/// A shelf of the ABS `personalized` view ("Continue Listening",
/// "Recently Added", …) — used to fill exactly those two rows completely while
/// the full list still loads progressively.
nonisolated struct PersonalizedShelf: Decodable {
    let id: String
    let entities: [LibraryItem]?
}

nonisolated struct LibraryItem: Codable, Identifiable {
    let id: String
    let media: LibraryItemMedia?
    let addedAt: Double?

    var title: String {
        media?.metadata?.title ?? String(localized: "Unknown Title")
    }

    var author: String? {
        media?.metadata?.authorName
    }
}

// MARK: - Book details (expanded endpoint, for the player)

nonisolated struct LibraryItemDetail: Codable, Identifiable {
    let id: String
    let media: LibraryItemMedia
    let userMediaProgress: MediaProgress?
}

nonisolated struct LibraryItemMedia: Codable {
    let metadata: LibraryItemMetadata?
    let duration: Double?
    let chapters: [ABSChapter]?
    let tracks: [ABSAudioTrack]?
    /// Podcast libraries only: the show's episodes (detail endpoint).
    /// Default nil so existing memberwise-init callers keep building.
    var episodes: [ABSPodcastEpisode]? = nil
}

/// F3: author reference from the expanded item payload — carries the server id
/// the author-image endpoint needs (the flat `authorName` string does not).
nonisolated struct ABSAuthorRef: Codable, Identifiable {
    let id: String
    let name: String?
}

nonisolated struct LibraryItemMetadata: Codable {
    let title: String?
    let authorName: String?
    /// F3: authors with server ids (expanded payload only). Default nil keeps
    /// existing memberwise-init callers valid.
    var authors: [ABSAuthorRef]? = nil
    let narratorName: String?
    let seriesName: String?
    let genres: [String]?
    let publishedYear: LenientString?
    let description: String?
    /// Podcasts only: feed URL (for cross-source dedup with RSS).
    /// Default nil → existing memberwise-init callers stay valid.
    var feedUrl: String? = nil
}

/// A podcast episode of an ABS show (`media.episodes[]` in the detail endpoint).
/// `audioTrack` is the streamable track (contentUrl relative to the server).
nonisolated struct ABSPodcastEpisode: Codable, Identifiable {
    let id: String
    let title: String?
    let subtitle: String?
    let description: String?
    let publishedAt: Double?   // ms seit 1970
    let duration: Double?
    let index: Int?
    let season: String?
    let episode: String?
    let audioTrack: ABSAudioTrack?
    /// The episode's chapters, if the server includes them (else nil).
    var chapters: [ABSChapter]? = nil
    /// Original feed `guid`/enclosure — bridge key to the `rss:` ids so the same
    /// episode shares one history across both sources (RSS + ABS).
    var guid: String? = nil
    var enclosure: ABSEnclosure? = nil
}

/// Enclosure of a feed episode (only the URL matters to us as a fallback key).
nonisolated struct ABSEnclosure: Codable {
    let url: String?
}

/// Some Audiobookshelf fields (e.g. publishedYear) return a string on some
/// server versions and a number on others. This wrapper accepts both instead of
/// failing the whole decode on a type mismatch.
nonisolated struct LenientString: Codable {
    let value: String

    /// Direct construction (providers mapping non-ABS sources, e.g. album year).
    init(_ value: String) { self.value = value }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let s = try? container.decode(String.self) {
            value = s
        } else if let i = try? container.decode(Int.self) {
            value = String(i)
        } else if let d = try? container.decode(Double.self) {
            value = String(Int(d))
        } else {
            value = ""
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(value)
    }
}

nonisolated struct ABSChapter: Codable, Identifiable, Equatable {
    let id: Int
    let start: Double
    let end: Double
    let title: String
}

nonisolated struct ABSAudioTrack: Codable {
    let index: Int?
    let startOffset: Double?
    let duration: Double?
    let contentUrl: String
    /// File metadata (size in bytes) — used for the free-space check
    /// before a download starts.
    let metadata: ABSFileMetadata?
}

nonisolated struct ABSFileMetadata: Codable {
    let size: Int64?
    /// The name of THIS track, when the source states one. Audiobookshelf
    /// ships none (a book's parts have no titles of their own); catalogue
    /// releases do, and without a place to put it the app fell back to the
    /// file name.
    var title: String? = nil
}

// MARK: - Progress

nonisolated struct MediaProgress: Codable {
    let currentTime: Double?
    let duration: Double?
    let progress: Double?
    let isFinished: Bool?
    /// ms since 1970 — for the device reconcile (newer entry wins).
    let lastUpdate: Double?
}
