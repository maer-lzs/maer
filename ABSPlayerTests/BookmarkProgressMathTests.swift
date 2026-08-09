// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import ABSPlayer

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
}
#endif
