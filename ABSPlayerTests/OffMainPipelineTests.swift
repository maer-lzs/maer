// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later

#if canImport(Testing)
import Testing
import Foundation
@testable import ABSPlayer

/// S-Pass regression: the model types must stay decodable OFF the main actor
/// (nonisolated conformances) — a re-isolated model would silently move the
/// big decodes back onto the UI thread (compile error in Swift 6, runtime
/// assertion here in mode 5).
struct OffMainDecodeTests {

    private let libraryPageJSON = Data("""
    {"results":[{"id":"b1","addedAt":123,"media":{"metadata":{"title":"T","authorName":"A"},"duration":10}}],"total":1}
    """.utf8)

    @Test("Library page decodes identically on a detached task")
    func decodeOffMainEqualsOnMain() async throws {
        let onMain = try JSONDecoder().decode(LibraryItemsResponse.self, from: libraryPageJSON)
        let offMain = try await Task.detached(priority: .userInitiated) { [libraryPageJSON] in
            try JSONDecoder().decode(LibraryItemsResponse.self, from: libraryPageJSON)
        }.value
        #expect(onMain.results.map(\.id) == offMain.results.map(\.id))
        #expect(onMain.total == offMain.total)
        #expect(offMain.results.first?.title == "T")
    }

    // MARK: - S6: off-main rebuild equivalence

    private func entry(_ id: String, title: String, added: Double, started: Bool = false) -> LibraryItem {
        LibraryItem(
            id: id,
            media: LibraryItemMedia(
                metadata: LibraryItemMetadata(title: title, authorName: nil, narratorName: nil,
                                              seriesName: nil, genres: nil, publishedYear: nil,
                                              description: nil),
                duration: 100, chapters: nil, tracks: nil
            ),
            addedAt: added
        )
    }

    @Test("computeRebuild output matches the on-main derivation rules")
    func rebuildSnapshotEquivalence() async {
        let items = [entry("b1", title: "Zeta", added: 10),
                     entry("b2", title: "Alpha", added: 30)]
        let seedItem = entry("b3", title: "SeedBook", added: 20)
        let progress = [
            "b1": BookProgress(fraction: 0.5, isFinished: false, lastUpdate: 100),
            "b3": BookProgress(fraction: 0.2, isFinished: false, lastUpdate: 200),
        ]
        let input = LibraryViewModel.RebuildInput(
            items: items, progress: progress, queued: [:],
            localCache: [], seedContinue: [seedItem], seedRecent: [seedItem],
            sort: .titel, ascending: true, filter: .alle, downloadedIds: []
        )
        let output = await Task.detached { LibraryViewModel.computeRebuild(input) }.value

        #expect(output.entries.map(\.id) == ["b1", "b2"])
        // Continue: started b1 from the pages + seeded b3, newest lastUpdate first.
        #expect(output.continueListening.map(\.id) == ["b3", "b1"])
        // Recently: union incl. seed, newest addedAt first.
        #expect(output.recentlyAdded.map(\.id) == ["b2", "b3", "b1"])
        // Pre-warmed memo lists equal the pure statics over the same entries.
        #expect(output.sorted.map(\.id) == LibraryViewModel.sortedFiltered(
            entries: output.entries, sort: .titel, ascending: true,
            filter: .alle, downloadedIds: []).map(\.id))
        #expect(output.grouped.count == LibraryViewModel.seriesGrouped(
            entries: output.entries, ascending: true, filter: .alle, downloadedIds: []).count)
    }

    @Test("Downloaded filter over the snapshot mirrors isDownloaded semantics")
    func downloadedFilterSnapshot() {
        let entries = [
            LibraryEntry(item: entry("srv1", title: "A", added: 1), progress: nil),
            LibraryEntry(item: entry("local:x", title: "B", added: 2), progress: nil),
            LibraryEntry(item: entry("srv2", title: "C", added: 3), progress: nil),
        ]
        let filtered = LibraryViewModel.sortedFiltered(
            entries: entries, sort: .titel, ascending: true,
            filter: .heruntergeladen, downloadedIds: ["srv2"])
        // Local files are offline-available by definition; srv2 is downloaded.
        #expect(Set(filtered.map(\.id)) == ["local:x", "srv2"])
    }

    @Test func subsonicEnvelopeDecodesOffMain() async throws {
        let json = Data("""
        {"subsonic-response":{"status":"ok","version":"1.16.1","albumList2":{"album":[{"id":"al1","name":"N","artist":"Ar","created":"2026-01-01T00:00:00.000Z"}]}}}
        """.utf8)
        let env = try await Task.detached {
            try JSONDecoder().decode(SubsonicEnvelope.self, from: json)
        }.value
        #expect(env.subsonicResponse.status == "ok")
        #expect(env.subsonicResponse.albumList2?.album?.first?.id == "al1")
    }
}
#endif
