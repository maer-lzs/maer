// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// Package 3: reconstruct a playlist's continue position from a per-song
/// bookmark (song offset within the playlist + position inside the song).
struct BookmarkProgressMathTests {
    // A 3-song playlist: song A [0,180), B [180,420), C [420,600).
    private let songs: [(id: String, start: Double)] = [("A", 0), ("B", 180), ("C", 420)]

    @Test func addsSongOffsetToBookmarkPosition() {
        // 30 s into song B → 180 + 30 = 210 s of the whole playlist.
        #expect(BookmarkProgressMath.playlistCurrentTime(songId: "B", positionMs: 30_000, songs: songs) == 210)
        // Start of song C.
        #expect(BookmarkProgressMath.playlistCurrentTime(songId: "C", positionMs: 0, songs: songs) == 420)
    }

    @Test func songNoLongerInPlaylistReturnsNil() {
        // Edited out since last listen → cleanly dropped, not shown broken.
        #expect(BookmarkProgressMath.playlistCurrentTime(songId: "Z", positionMs: 5_000, songs: songs) == nil)
    }

    @Test func negativePositionClampsToOffset() {
        #expect(BookmarkProgressMath.playlistCurrentTime(songId: "B", positionMs: -1_000, songs: songs) == 180)
    }

    @Test func progressFractionAndFinished() {
        let p = BookmarkProgressMath.progress(currentTime: 300, duration: 600, lastUpdate: 42)
        #expect(p.fraction == 0.5)
        #expect(!p.isFinished)
        #expect(p.currentTime == 300)
        #expect(p.lastUpdate == 42)
        #expect(p.isStarted)

        let done = BookmarkProgressMath.progress(currentTime: 600, duration: 600, lastUpdate: 1)
        #expect(done.isFinished)

        // Zero/unknown duration must not divide by zero.
        #expect(BookmarkProgressMath.progress(currentTime: 10, duration: 0, lastUpdate: 0).fraction == 0)
    }

    @Test func mostRecentPicksLatestStamp() {
        #expect(BookmarkProgressMath.mostRecent([10, 90, 40]) == 1)
        #expect(BookmarkProgressMath.mostRecent([]) == nil)
    }

    /// D2 a: a Booksonic book is an album with bookmarks on the server.
    /// The one rule for the library read and the resume on open: only the
    /// item's own bookmarks count, each goes back on the time line by its
    /// song's offset, the most recently changed wins, a song that left the
    /// item is dropped, and nothing is nothing.
    @Test("ein Booksonic-Buch: der juengste Bookmark gewinnt, ein Song ausserhalb faellt, fremde Items bleiben aussen")
    func resumeFromBookmarks() throws {
        func bookmark(_ song: String, _ ms: Int, _ changed: String, comment: String = "sub:album:book") throws -> SubsonicBookmark {
            try JSONDecoder().decode(SubsonicBookmark.self, from: Data(
                "{\"position\":\(ms),\"comment\":\"\(comment)\",\"changed\":\"\(changed)\",\"entry\":{\"id\":\"\(song)\"}}".utf8))
        }
        let stamp: (SubsonicBookmark) -> Double = {
            ISO8601DateFormatter().date(from: $0.changed ?? "")!.timeIntervalSince1970 * 1000
        }
        let bookmarks = [
            try bookmark("A", 60_000, "2026-09-06T10:00:00Z"),
            try bookmark("B", 30_000, "2026-09-06T11:00:00Z"),
            try bookmark("Z", 5_000, "2026-09-06T12:00:00Z"),
            try bookmark("C", 1_000, "2026-09-06T13:00:00Z", comment: "sub:album:other"),
        ]
        let pick = try #require(BookmarkProgressMath.resume(bookmarks: bookmarks, itemId: "sub:album:book",
                                                            songs: songs, stamp: stamp))
        // B at 30 s is the newest that still maps: 180 + 30. Z left the
        // book, C belongs to another item.
        #expect(pick.time == 210)
        #expect(pick.stamp == stamp(bookmarks[1]))
        #expect(BookmarkProgressMath.resume(bookmarks: [], itemId: "sub:album:book", songs: songs, stamp: stamp)?.time == nil)
        #expect(BookmarkProgressMath.resume(bookmarks: [try bookmark("Z", 1, "2026-09-06T10:00:00Z")],
                                            itemId: "sub:album:book", songs: songs, stamp: stamp)?.time == nil)
        // The end of the book is finished, through the same progress rule.
        let done = BookmarkProgressMath.progress(currentTime: 600, duration: 600, lastUpdate: pick.stamp)
        #expect(done.isFinished)
    }
}
#endif
