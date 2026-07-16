#if DEBUG
import Foundation

/// DEBUG-only UI-test seeding. Active ONLY when the process is launched with the
/// `-uitest` argument (the ABSPlayerUITests harness passes it) — the entire file
/// compiles out of Release builds (`#if DEBUG`). It bypasses the login gate and
/// injects deterministic fake content across the providers so read-only UI
/// journeys (mixed queue, Home, badges) run without a live server. It never
/// touches the network or a real account.
@MainActor
enum UITestSeed {
    static var isActive: Bool { ProcessInfo.processInfo.arguments.contains("-uitest") }

    static func applyIfRequested() {
        guard isActive else { return }
        let session = AppSession.shared
        session.authViewModel.isLoggedIn = true

        // Audiobooks — one with chapters, one without.
        let books = [
            bookEntry(id: "seed-book-1", title: "Seed Book One", author: "Ada Author",
                      chapters: [chapter(0, 0, 1800, "Chapter 1"), chapter(1, 1800, 3600, "Chapter 2")]),
            bookEntry(id: "seed-book-2", title: "Seed Book Two", author: "Ben Author", chapters: nil),
        ]
        session.libraryViewModel.entries = books
        session.libraryViewModel.recentlyAdded = books

        // Podcast show + episodes (RSS resolvable via the subscriptions index).
        let show = PodcastShow(
            id: "seed-show", title: "Seed Show", author: "Cara Host", artworkURL: nil,
            description: "A seeded podcast.", feedURL: "https://seed.example/feed",
            episodes: [
                episode(guid: "rss:seed:ep-1", title: "Seed Episode One"),
                episode(guid: "rss:seed:ep-2", title: "Seed Episode Two"),
            ])
        PodcastSubscriptions.shared._seedForUITest([show])

        // Music album — resolvable in the queue without a Subsonic server.
        SubsonicProvider.shared._seedForUITest([
            musicAlbum(id: "sub:album:seed-1", title: "Seed Album", artist: "The Seeds"),
        ])

        // Mixed Up-Next queue: a book, an album and an episode.
        let queue = PlayQueue.shared
        queue.clear()
        queue.playLast("seed-book-1")
        queue.playLast("sub:album:seed-1")
        queue.playLast("rss:seed:ep-1")
    }

    // MARK: - Fixtures

    private static func bookEntry(id: String, title: String, author: String, chapters: [ABSChapter]?) -> LibraryEntry {
        LibraryEntry(item: LibraryItem(
            id: id,
            media: LibraryItemMedia(
                metadata: LibraryItemMetadata(title: title, authorName: author, narratorName: nil,
                                              seriesName: nil, genres: nil, publishedYear: nil, description: nil),
                duration: 3600, chapters: chapters, tracks: nil),
            addedAt: 0), progress: nil)
    }

    private static func musicAlbum(id: String, title: String, artist: String) -> LibraryItem {
        LibraryItem(id: id, media: LibraryItemMedia(
            metadata: LibraryItemMetadata(title: title, authorName: artist, narratorName: nil,
                                          seriesName: nil, genres: nil, publishedYear: nil, description: nil),
            duration: 2400, chapters: nil, tracks: nil), addedAt: 0)
    }

    private static func chapter(_ id: Int, _ start: Double, _ end: Double, _ title: String) -> ABSChapter {
        ABSChapter(id: id, start: start, end: end, title: title)
    }

    private static func episode(guid: String, title: String) -> PodcastEpisode {
        PodcastEpisode(guid: guid, title: title, audioURL: "https://seed.example/\(guid).mp3",
                       pubDate: 1_700_000_000_000, duration: 1800, description: nil,
                       imageURL: nil, chaptersURL: nil)
    }
}
#endif
