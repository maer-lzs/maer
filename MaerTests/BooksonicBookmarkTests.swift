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

    @Test("Die echte Antwort dekodiert, mit allen Feldern die die Regel braucht")
    func realShapeDecodes() throws {
        let list = try bookmarks()
        #expect(list.count == 1)
        let mark = try #require(list.first)
        // Die Position steht in MILLISEKUNDEN, wie die Subsonic-Beschreibung
        // sie fuehrt; Maer rechnet intern in Sekunden und wandelt an dieser
        // Tuer. Geschrieben wurden 90500 ms.
        #expect(mark.position == 90500)
        // Der Kommentar traegt die Item-Kennung: eine Marke kennt nur Song
        // und Position, die Zugehoerigkeit zum Album steht nur hier.
        #expect(mark.comment == "sub:album:0")
        #expect(mark.changed == "2026-09-07T18:20:39.067Z")
        // `entry` ist das GANZE Song-Objekt, nicht bloss eine Kennung.
        let entry = try #require(mark.entry)
        #expect(entry.id == "5")
        #expect(entry.duration == 425)
    }

    @Test("Die Marke landet auf der Zeitachse des Buchs, nicht auf der des Songs")
    func resumeLandsOnTheBooksTimeline() throws {
        // Album 0 des Prüfstands: zwei Spuren, 246 s und 425 s. Die Marke
        // sitzt in der ZWEITEN, also 246 s Vorlauf plus 90,5 s darin.
        let songs = [(id: "4", start: 0.0), (id: "5", start: 246.0)]
        let pick = try #require(BookmarkProgressMath.resume(
            bookmarks: try bookmarks(), itemId: "sub:album:0", songs: songs,
            stamp: { _ in 1 }))
        #expect(pick.time == 336.5)
    }

    @Test("Eine Marke, deren Song nicht mehr im Album steht, faellt sauber weg")
    func bookmarkOfARemovedSongIsDropped() throws {
        // Der Gegenlauf zur Regel oben: dasselbe Album ohne die zweite Spur.
        // Ohne diesen Fall koennte `resume` alles zurueckgeben und der Zeuge
        // saehe es nicht.
        let songs = [(id: "4", start: 0.0)]
        #expect(BookmarkProgressMath.resume(bookmarks: try bookmarks(), itemId: "sub:album:0",
                                            songs: songs, stamp: { _ in 1 }) == nil)
    }

    @Test("Eine fremde Item-Kennung im Kommentar traegt nichts hierher")
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
    @Test("Subsonic: die Lesezeichen werden jedes Mal gefragt, und nach einem gescheiterten Lesen wird nicht geschrieben", .needsTheSources)
    func theBookmarksAreAskedEachTime() throws {
        let source = SyncContractFenceTests.stripped(try String(
            contentsOf: SourceTree.root.appendingPathComponent("Sources/Providers/SubsonicProvider.swift"), encoding: .utf8))
        #expect(!source.contains("bookmarksCache"), "a list of the bookmarks is kept for the process again")
        #expect(source.contains("guard let client else { return [] }\n        return try await client.getBookmarks()"))
        #expect(!source.contains("try? await loadBookmarks()\n              let songs"), "the open swallows a failed read")
        #expect(source.contains("bookmarksUnread.insert(itemId)"), "a failed read at the open is not remembered")
        let held = try #require(source.range(of: "if bookmarksUnread.contains(itemId) {"), "the write does not ask whether the open read")
        let write = try #require(source.range(of: "try await client.createBookmark("))
        #expect(held.lowerBound < write.lowerBound, "the hold stands after the write")
    }
}
#endif
