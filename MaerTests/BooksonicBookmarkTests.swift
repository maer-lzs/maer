// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// The decoder and the resume rule on the REAL answer of a Booksonic
/// Air 2201.1.0, captured 07.09.2026 against a live instance and frozen as
/// a fixture with the account cut out. A hand-built shape would only
/// prove that we agree with ourselves; a missing key in the real one
/// THROWS, and the read site swallows it with `try?`, so the row would go
/// quietly empty. Measured beside it, and the reason this fixture exists:
/// the server answers `v=1.16.1` with error 30 and names 1.15.0 in the
/// same body, so a client that does not step down never gets this far.
struct BooksonicBookmarkTests {
    private func response() throws -> Data {
        try CorpusFixture.data("getBookmarks-air-2201.1.0", ext: "json", subdirectory: "Booksonic")
    }

    private func bookmarks() throws -> [SubsonicBookmark] {
        struct Envelope: Decodable {
            struct Inner: Decodable { let bookmarks: SubsonicBookmarks? }
            let inner: Inner
            enum CodingKeys: String, CodingKey { case inner = "subsonic-response" }
        }
        let decoded = try JSONDecoder().decode(Envelope.self, from: try response())
        return decoded.inner.bookmarks?.bookmark ?? []
    }

    @Test("The real answer decodes, with all fields that the rule needs")
    func realShapeDecodes() throws {
        let list = try bookmarks()
        #expect(list.count == 1)
        let mark = try #require(list.first)
        // The position is in MILLISECONDS, as the Subsonic description
        // has it; Maer calculates internally in seconds and converts at this
        // door. 90500 ms were written.
        #expect(mark.position == 90500)
        // The comment carries the item identifier: a mark knows only song
        // and position, the membership in the album is only here.
        #expect(mark.comment == "sub:album:0")
        #expect(mark.changed == "2026-09-07T18:20:39.067Z")
        // `entry` is the WHOLE song object, not merely an identifier.
        let entry = try #require(mark.entry)
        #expect(entry.id == "5")
        #expect(entry.duration == 425)
    }

    @Test("The mark lands on the timeline of the book, not on that of the song")
    func resumeLandsOnTheBooksTimeline() throws {
        // Album 0 of the test bench: two tracks, 246 s and 425 s. The mark
        // sits in the SECOND, so 246 s lead plus 90.5 s into it.
        let songs = [(id: "4", start: 0.0), (id: "5", start: 246.0)]
        let pick = try #require(BookmarkProgressMath.resume(
            bookmarks: try bookmarks(), itemId: "sub:album:0", songs: songs,
            stamp: { _ in 1 }))
        #expect(pick.time == 336.5)
    }

    @Test("A mark whose song is no longer in the album drops out cleanly")
    func bookmarkOfARemovedSongIsDropped() throws {
        // The counterpart to the rule above: the same album without the second track.
        // Without this case `resume` could return everything and the witness
        // would not see it.
        let songs = [(id: "4", start: 0.0)]
        #expect(BookmarkProgressMath.resume(bookmarks: try bookmarks(), itemId: "sub:album:0",
                                            songs: songs, stamp: { _ in 1 }) == nil)
    }

    @Test("A foreign item identifier in the comment carries nothing over here")
    func aForeignCommentIsNotOurs() throws {
        let songs = [(id: "4", start: 0.0), (id: "5", start: 246.0)]
        #expect(BookmarkProgressMath.resume(bookmarks: try bookmarks(), itemId: "sub:album:9",
                                            songs: songs, stamp: { _ in 1 }) == nil)
    }

    /// The bookmarks are asked at every open and every read of progress,
    /// never from a list kept for the process: a stand another device wrote
    /// since is seen before this device writes. An open whose read failed
    /// writes no bookmark until a read succeeds. The provider is one
    /// instance without a client to hand in, so this is read at the source.
    @Test("Subsonic: the bookmarks are asked every time, and after a failed read nothing is written", .needsTheSources)
    func theBookmarksAreAskedEachTime() throws {
        let source = SyncContractFenceTests.stripped(try String(
            contentsOf: SourceTree.root.appendingPathComponent("Sources/Providers/SubsonicProvider.swift"), encoding: .utf8))
        #expect(!source.contains("bookmarksCache"), "a list of the bookmarks is kept for the process again")
        #expect(source.contains("guard let client else { throw SubsonicClient.SubsonicError.network }\n        return try await client.getBookmarks()"),
                "without a client the read says none, and the open clears the hold without a read")
        #expect(!source.contains("try? await loadBookmarks()"), "a failed read of the bookmarks passes without a line")
        #expect(source.contains("BOOKMARK read failed by=progress"))
        #expect(!source.contains("try? await loadBookmarks()\n              let songs"), "the open swallows a failed read")
        #expect(source.contains("bookmarksUnread.insert(itemId)"), "a failed read at the open is not remembered")
        let held = try #require(source.range(of: "if bookmarksUnread.contains(itemId) {"), "the write does not ask whether the open read")
        let write = try #require(source.range(of: "try await client.createBookmark("))
        #expect(held.lowerBound < write.lowerBound, "the hold stands after the write")
    }
}
#endif
