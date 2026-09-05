// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// The library rows: the diff names exactly what changed, the store gives
/// the cache back in its order with every field, and "no rows" reads as no
/// cache, not as an empty library.
struct LibraryRowStoreTests {
    private func item(_ id: String, title: String = "T", addedAt: Double = 1) -> LibraryItem {
        LibraryItem(
            id: id,
            media: LibraryItemMedia(
                metadata: LibraryItemMetadata(title: title, authorName: "A", narratorName: nil,
                                              seriesName: "S", genres: ["g"], publishedYear: LenientString("1999"),
                                              description: "d"),
                duration: 100,
                chapters: [ABSChapter(id: 0, start: 0, end: 50, title: "One")],
                tracks: [ABSAudioTrack(index: 1, startOffset: 0, duration: 100, contentUrl: "/t/1",
                                       metadata: ABSFileMetadata(size: 42, title: nil))]
            ),
            addedAt: addedAt
        )
    }

    private func store() async throws -> LibraryRowStore {
        try await LibraryRowStore(connection: try SQLiteConnection(path: ":memory:"))
    }

    @Test("Diff: unveraendert leer; neuer/geaenderter/bewegter Titel eine Zeile; Fortschritt je Eintrag")
    func diffNamesWhatChanged() {
        let before = LibraryDiskCache(items: [item("a"), item("b")],
                                      progress: ["a": BookProgress(fraction: 0.2, isFinished: false, lastUpdate: 1)])
        #expect(LibraryRowDiff.compute(previous: before, current: before).isEmpty)
        let all = LibraryRowDiff.all(before)
        #expect(all.itemsUpserted.map(\.position) == [0, 1] && all.progressUpserted.count == 1)

        var progress = before.progress
        progress["b"] = BookProgress(fraction: 1, isFinished: true, lastUpdate: 2)
        let after = LibraryDiskCache(items: [item("b"), item("a", title: "Renamed"), item("c")], progress: progress)
        let diff = LibraryRowDiff.compute(previous: before, current: after)
        #expect(diff.itemsUpserted.map(\.item.id) == ["b", "a", "c"], "b moved, a changed, c is new")
        #expect(diff.itemsRemoved.isEmpty)
        #expect(diff.progressUpserted.map(\.itemId) == ["b"], "a's progress is the same entry")
        #expect(diff.progressRemoved.isEmpty)

        let shrunk = LibraryDiskCache(items: [item("a")], progress: [:])
        let gone = LibraryRowDiff.compute(previous: before, current: shrunk)
        #expect(gone.itemsRemoved == ["b"] && gone.itemsUpserted.isEmpty)
        #expect(gone.progressRemoved == ["a"] && gone.progressUpserted.isEmpty)
    }

    @Test("Ersetzen, Diff anwenden, Zuruecklesen: Reihenfolge und jedes Feld; keine Zeilen = kein Cache")
    func roundTripAndApply() async throws {
        let store = try await store()
        #expect(try await store.loadAll() == nil, "no rows is no cache, not an empty library")
        let before = LibraryDiskCache(items: [item("a"), item("b")],
                                      progress: ["a": BookProgress(fraction: 0.2, isFinished: false, lastUpdate: 1, currentTime: 20)])
        #expect(try await store.replaceAll(before) == LibraryRowStore.Counts(items: 2, progress: 1))
        let loaded = try #require(try await store.loadAll())
        #expect(loaded.items == before.items)
        #expect(loaded.progress == before.progress)

        let after = LibraryDiskCache(items: [item("b"), item("c")],
                                     progress: ["c": BookProgress(fraction: 0.5, isFinished: false, lastUpdate: 3)])
        let counts = try await store.apply(LibraryRowDiff.compute(previous: before, current: after))
        #expect(counts == LibraryRowStore.Counts(items: 2, progress: 1))
        let reloaded = try #require(try await store.loadAll())
        #expect(reloaded.items.map(\.id) == ["b", "c"])
        #expect(reloaded.progress.keys.sorted() == ["c"])
        #expect(try await store.counts() == LibraryRowStore.Counts(items: 2, progress: 1))
        #expect(try await store.apply(LibraryRowDiff()) == LibraryRowStore.Counts(items: 0, progress: 0))
    }
}
#endif
