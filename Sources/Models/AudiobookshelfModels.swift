// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation

// MARK: - Sign-in

/// Response of POST /login. Older servers return the long-lived `token`, newer
/// ones (JWT auth from v2.26) an `accessToken`. Both optional, the long-lived
/// one is preferred.
nonisolated struct LoginResponse: Decodable {
    let user: LoginUser
}

nonisolated struct LoginUser: Decodable {
    let token: String?
    let accessToken: String?
}

/// Response of /api/me. Holds all of the user's progress entries.
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
    /// Set only for podcast progress. Identifies the episode.
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
    /// Absolute position in seconds. Fallback to recompute fraction locally
    /// from the book duration when the server omits it (multi-file books with a
    /// missing server duration). Optional: old disk caches.
    var currentTime: Double? = nil
    /// Within the person's "counts as played" tail of the end (`PlayedTail`),
    /// set where the entry is built with its duration and id. Optional so an
    /// old disk cache without the key still decodes. Never sent anywhere.
    var withinTail: Bool? = nil

    /// The same progress, with the tail question answered against a book's
    /// duration. Nothing but the new field changes.
    func judged(duration: Double?, tail: Double) -> BookProgress {
        var copy = self
        guard let duration, duration > 0 else { return copy }
        let position = currentTime ?? fraction * duration
        copy.withinTail = ProgressMark.withinTail(position: position, duration: duration, tail: tail)
        return copy
    }

    /// The progress of a title whose mark lives on the device (a catalog
    /// title): the flag carries the TRUE end, the tail its own field, as for
    /// every library title. `markedDuration` is the length the mark was
    /// written with, `itemDuration` today's.
    static func fromDeviceMark(position: Double, updatedAtMs: Double, markedDuration: Double?,
                               itemDuration: Double?, tail: Double) -> BookProgress {
        let duration = markedDuration ?? itemDuration ?? 0
        let stored = [position, updatedAtMs] + (markedDuration.map { [$0] } ?? [])
        return BookProgress(fraction: duration > 0 ? min(position / duration, 1) : 0,
                            isFinished: ProgressMark.reachedEnd(stored: stored, currentDuration: duration),
                            lastUpdate: updatedAtMs,
                            currentTime: position)
            .judged(duration: duration, tail: tail)
    }

    /// THE finished question, answered once and here.
    ///
    /// The flag alone is not enough, measured on a real book: position and
    /// duration were both 18:40:56 on the server for hours, and the flag was
    /// still false. So the title stood at the top of Continue although it had
    /// been listened through. A flag can fail to arrive; numbers that say the
    /// same thing twice cannot. Whoever asks "is this done" asks this, so the
    /// row, the filter and the badge can never disagree.
    ///
    /// Same lesson as `playedSentinel` one level up: the finished question must
    /// not hang on a marker when the values beside it are unambiguous.
    /// The numeric witness is deliberately `>= 0.9999`, not a comfortable
    /// margin like 0.99: it must mean "the numbers say COMPLETE", with room for
    /// float noise and nothing else. A percentage threshold would declare books
    /// finished that are not. A 20-hour book at 99 % has twelve minutes left.
    ///
    /// The person's tail (`withinTail`) counts too: a book with credits is
    /// done a minute early for the rows and badges. The server flag stays
    /// what the server said; nothing here writes it.
    var countsAsFinished: Bool {
        atTrueEnd || withinTail == true
    }

    /// Finished without the person's tail: the flag, or numbers that say
    /// complete. What the finished toggle asks.
    var atTrueEnd: Bool {
        isFinished || fraction >= Self.completeFraction
    }

    /// The finished toggle of a book, by the one rule.
    var markGesture: ProgressMark.MarkGesture {
        ProgressMark.markGesture(atTrueEnd: atTrueEnd)
    }

    /// "The numbers say COMPLETE", with room for float noise only.
    static let completeFraction = 0.9999   // progress-fence: the one home of this number

    var isStarted: Bool { fraction > 0.001 && !countsAsFinished }

    /// Remaining-time text ("3 h 12 min left") from the book duration. Nil when
    /// no duration is known (then show percent as fallback).
    func remainingText(bookDuration: Double?) -> String? {
        guard let bookDuration, bookDuration > 0 else { return nil }
        let listened = currentTime ?? fraction * bookDuration
        let remaining = max(0, bookDuration - listened)
        return DurationText.remaining(seconds: remaining)
    }
}

// MARK: - Libraries

nonisolated struct LibrariesResponse: Decodable {
    let libraries: [ABSLibrary]
}

nonisolated struct ABSLibrary: Decodable, Identifiable {
    let id: String
    let name: String
    /// "book" | "podcast". Distinguishes audiobook from podcast libraries.
    /// Default nil → existing memberwise-init callers (RSS/Local) stay valid.
    var mediaType: String? = nil
    /// Library folders (the list endpoint usually includes them). Target path
    /// for a newly created podcast subscription.
    var folders: [ABSFolder]? = nil

    var isPodcast: Bool { mediaType == "podcast" }
}

// MARK: - Podcast management (folders, feed metadata)

/// A library folder. Target path for a newly created podcast subscription.
nonisolated struct ABSFolder: Decodable, Identifiable {
    let id: String
    let fullPath: String?
}

/// `GET /api/libraries/{id}` returns the library object DIRECTLY (folders at
/// the top level). NOT wrapped in `{ library: … }`.
nonisolated struct LibraryWithFolders: Decodable {
    let folders: [ABSFolder]?
}

/// Response of POST /api/podcasts/feed. Server-side parsed feed.
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
    /// The feed's picture. The server reports it as `image`
    /// (`podcastUtils.js` in Audiobookshelf 2.37); this model read
    /// `imageUrl`, a name the server never sends, so every new show was
    /// created without its picture.
    let image: String?
    let feedUrl: String?
}

// MARK: - Book list (list endpoint)

nonisolated struct LibraryItemsResponse: Decodable {
    let results: [LibraryItem]
    /// Total number of items in the library (server paging). Drives how many
    /// pages the progressive load still has to fetch.
    let total: Int?
}

/// A shelf of the ABS `personalized` view ("Continue Listening",
/// "Recently Added", …). Used to fill exactly those two rows completely while
/// the full list still loads progressively.
nonisolated struct PersonalizedShelf: Decodable {
    let id: String
    let entities: [LibraryItem]?
}

nonisolated struct LibraryItem: Codable, Identifiable, Equatable {
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

nonisolated struct LibraryItemDetail: Codable, Identifiable, Equatable, Sendable {
    let id: String
    let media: LibraryItemMedia
    let userMediaProgress: MediaProgress?
}

nonisolated struct LibraryItemMedia: Codable, Equatable {
    let metadata: LibraryItemMetadata?
    let duration: Double?
    let chapters: [ABSChapter]?
    let tracks: [ABSAudioTrack]?
    /// Podcast libraries only: the show's episodes (detail endpoint).
    /// Default nil so existing memberwise-init callers keep building.
    var episodes: [ABSPodcastEpisode]? = nil
}

/// Author reference from the expanded item payload. Carries the server id
/// the author-image endpoint needs (the flat `authorName` string does not).
nonisolated struct ABSAuthorRef: Codable, Identifiable, Equatable {
    let id: String
    let name: String?
}

nonisolated struct LibraryItemMetadata: Codable, Equatable {
    let title: String?
    let authorName: String?
    /// Authors with server ids (expanded payload only). Default nil keeps
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
nonisolated struct ABSPodcastEpisode: Codable, Identifiable, Equatable {
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
    /// Original feed `guid`/enclosure. Bridge key to the `rss:` ids so the same
    /// episode shares one history across both sources (RSS + ABS).
    var guid: String? = nil
    var enclosure: ABSEnclosure? = nil
}

/// Enclosure of a feed episode (only the URL matters to us as a fallback key).
nonisolated struct ABSEnclosure: Codable, Equatable {
    let url: String?
}

/// Some Audiobookshelf fields (e.g. publishedYear) return a string on some
/// server versions and a number on others. This wrapper accepts both instead of
/// failing the whole decode on a type mismatch.
nonisolated struct LenientString: Codable, Equatable {
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

nonisolated struct ABSAudioTrack: Codable, Equatable {
    let index: Int?
    let startOffset: Double?
    let duration: Double?
    let contentUrl: String
    /// File metadata (size in bytes). Used for the free-space check
    /// before a download starts.
    let metadata: ABSFileMetadata?
}

nonisolated struct ABSFileMetadata: Codable, Equatable {
    let size: Int64?
    /// The name of THIS track, when the source states one. Audiobookshelf
    /// ships none (a book's parts have no titles of their own); catalogue
    /// releases do, and without a place to put it the app fell back to the
    /// file name.
    var title: String? = nil
    /// The type the source states for the original file. A music server
    /// that may transcode states it; a download is held to `size` only
    /// when its answer carries this type (`TrackFileSize.Claim`).
    var contentType: String? = nil
}

// MARK: - Progress

nonisolated struct MediaProgress: Codable, Equatable, Sendable {
    let currentTime: Double?
    let duration: Double?
    let progress: Double?
    let isFinished: Bool?
    /// ms since 1970. For the device reconcile (newer entry wins).
    let lastUpdate: Double?
}
