// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// A secondary audiobook source that cannot answer keeps its books and bars
/// of the round before; one that answers empty is empty; a neighbour is not
/// touched by either.
struct SecondaryShelfTests {
    private struct Offline: Error {}

    private static func item(_ id: String) -> LibraryItem {
        LibraryItem(
            id: id,
            media: LibraryItemMedia(
                metadata: LibraryItemMetadata(title: "T", authorName: nil, narratorName: nil,
                                              seriesName: nil, genres: nil, publishedYear: nil,
                                              description: nil),
                duration: 100, chapters: nil, tracks: nil
            ),
            addedAt: 1
        )
    }

    private static func answering(_ key: String, _ ids: [String], _ progress: [String: Double]) -> SecondaryShelf.Source {
        let items = ids.map(item)
        let bars = progress.mapValues { BookProgress(fraction: $0, isFinished: false, lastUpdate: 1) }
        return .init(key: key, items: { items }, progress: { bars })
    }

    private static func failing(_ key: String) -> SecondaryShelf.Source {
        .init(key: key, items: { throw Offline() }, progress: { throw Offline() })
    }

    private static func owners(_ entries: [LibraryEntry]) -> [String: String] {
        // Not unique by force: a wrong rule may put a book in twice, and the
        // witness must then fail on its expectation, not crash.
        Dictionary(entries.map { ($0.id, String($0.id.prefix { $0 != ":" })) }, uniquingKeysWith: { first, _ in first })
    }

    @Test("a secondary source that does not answer keeps books and bars over two rounds; answered empty is empty")
    func aFailedSourceKeepsItsBooks() async {
        let first = await SecondaryShelf.entries(of: [Self.answering("sub", ["sub:a"], ["sub:a": 0.4]),
                                                      Self.answering("local", ["local:x"], [:])],
                                                 previous: [], owners: [:])
        #expect(first.map(\.id) == ["sub:a", "local:x"], "the precondition: both sources on the shelf")
        // The network fails: the books stay, and so do their bars, also in
        // the round after, which builds on the round before.
        let second = await SecondaryShelf.entries(of: [Self.failing("sub"), Self.answering("local", ["local:x"], [:])],
                                                  previous: first, owners: Self.owners(first))
        #expect(second.map(\.id) == ["sub:a", "local:x"], "a source that could not answer left the shelf")
        #expect(second.first?.progress?.fraction == 0.4, "its bar went with the failed list")
        let third = await SecondaryShelf.entries(of: [Self.failing("sub"), Self.answering("local", ["local:x"], [:])],
                                                 previous: second, owners: Self.owners(second))
        #expect(third.map(\.id) == ["sub:a", "local:x"] && third.first?.progress?.fraction == 0.4,
                "the second failed round lost what the first kept")
        // An answer that is empty is an answer: the source's books leave,
        // the neighbour stays.
        let empty = await SecondaryShelf.entries(of: [Self.answering("sub", [], [:]), Self.answering("local", ["local:x"], [:])],
                                                 previous: third, owners: Self.owners(third))
        #expect(empty.map(\.id) == ["local:x"], "an empty answer kept the books of before")
        // The failing source keeps only its own books, never a neighbour's.
        let alone = await SecondaryShelf.entries(of: [Self.failing("sub")], previous: third, owners: Self.owners(third))
        #expect(alone.map(\.id) == ["sub:a"], "a failing source took a neighbour's books")
    }

    /// The list fails, the progress answers (with nothing for the kept
    /// books, as a Subsonic fetch that never throws does): the source keeps
    /// its books of the round before and their bars.
    @Test("if only the list fails and the progress answers, the source keeps books and bars")
    func aFailedListKeepsItsBarsWhenTheProgressAnswers() async {
        let first = await SecondaryShelf.entries(of: [Self.answering("sub", ["sub:a"], ["sub:a": 0.4])],
                                                 previous: [], owners: [:])
        let listDown = SecondaryShelf.Source(key: "sub", items: { throw Offline() }, progress: { [:] })
        let second = await SecondaryShelf.entries(of: [listDown], previous: first, owners: Self.owners(first))
        #expect(second.map(\.id) == ["sub:a"], "the kept book left the shelf")
        #expect(second.first?.progress?.fraction == 0.4, "the progress answer wiped the bar of a kept book")
    }
}
#endif
