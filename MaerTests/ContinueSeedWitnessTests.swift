// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// What the library's one rule makes of the harness's books: the books with
/// a stand that is neither finished nor hidden stand in Continue, the
/// finished one does not. The witness asks the rule with the seed's input,
/// so a row that shows fewer on a device is a question about that device's
/// state, not about the rule.
struct ContinueSeedWitnessTests {
    private static func book(_ id: String, _ title: String) -> LibraryItem {
        LibraryItem(id: id, media: LibraryItemMedia(
            metadata: LibraryItemMetadata(title: title, authorName: "A", narratorName: nil, seriesName: nil,
                                          genres: nil, publishedYear: nil, description: nil),
            duration: 3600, chapters: nil, tracks: nil), addedAt: 0)
    }

    @Test("die Regel stellt die begonnenen Buecher des Seeds in Weiterhoeren, das gehoerte nicht")
    func theSeedsStartedBooksStandInContinue() {
        let now = Date().timeIntervalSince1970 * 1000
        let items = [Self.book("seed-book-old", "Seed Book Old"), Self.book("seed-book-3", "Der Leuchtturmwärter"),
                     Self.book("seed-book-4", "Nordlicht"), Self.book("seed-book-6", "Die stille Bibliothek"),
                     Self.book("seed-book-7", "Fernweh")]
        let progress: [String: BookProgress] = [
            "seed-book-old": BookProgress(fraction: 0.4, isFinished: false, lastUpdate: now - 35 * 86_400_000),
            "seed-book-3": BookProgress(fraction: 1, isFinished: true, lastUpdate: now - 2 * 86_400_000),
            "seed-book-4": BookProgress(fraction: 0.6, isFinished: false, lastUpdate: now - 3_600_000,
                                        currentTime: 0.6 * 3600),
            "seed-book-6": BookProgress(fraction: 0.15, isFinished: false, lastUpdate: now - 26 * 3_600_000),
        ]
        let input = LibraryViewModel.RebuildInput(
            items: items, progress: progress, queued: [:], localCache: [],
            seedContinue: [], seedRecent: [], sort: .titel, ascending: true, filter: .alle,
            downloadedIds: [], hiddenMarkers: [:], continueExtras: [])
        let output = LibraryViewModel.computeRebuild(input)
        let ids = Set(output.continueListening.map(\.id))
        #expect(ids == ["seed-book-old", "seed-book-4", "seed-book-6"], "the rule counts \(ids.sorted())")
    }

    @Test("ein wartendes 0, das der Abgleich verwirft, ueberdeckt den Serverstand nicht: das Buch bleibt in Weiterhoeren")
    func aQueuedZeroTheFlushDropsCoversNothing() {
        let now = Date().timeIntervalSince1970 * 1000
        let progress = ["seed-book-old": BookProgress(fraction: 0.4, isFinished: false,
                                                      lastUpdate: now - 86_400_000)]
        let queued = ["seed-book-old": SyncQueue.PendingUpdate(currentTime: 0, duration: 3600,
                                                               isFinished: false, queuedAt: now)]
        let entry = LibraryViewModel.makeEntry(item: Self.book("seed-book-old", "Seed Book Old"),
                                               progress: progress, queued: queued)
        #expect(entry.progress?.fraction == 0.4)
        let input = LibraryViewModel.RebuildInput(
            items: [Self.book("seed-book-old", "Seed Book Old")], progress: progress, queued: queued,
            localCache: [], seedContinue: [], seedRecent: [], sort: .titel, ascending: true, filter: .alle,
            downloadedIds: [], hiddenMarkers: [:], continueExtras: [])
        #expect(LibraryViewModel.computeRebuild(input).continueListening.map(\.id) == ["seed-book-old"])
        // A queued state ahead of the server still shows over it.
        let ahead = ["seed-book-old": SyncQueue.PendingUpdate(currentTime: 2000, duration: 3600,
                                                              isFinished: false, queuedAt: now)]
        let shown = LibraryViewModel.makeEntry(item: Self.book("seed-book-old", "Seed Book Old"),
                                               progress: progress, queued: ahead)
        #expect(shown.progress?.currentTime == 2000)
    }

    @Test("Abgleich und Anzeige fragen die eine Regel ueber wartende Staende", .needsTheSources)
    func flushAndDisplayAskTheOneRule() throws {
        let read = { (path: String) in
            SyncContractFenceTests.stripped(
                try String(contentsOf: SourceTree.root.appendingPathComponent(path), encoding: .utf8))
        }
        let queue = try read("Sources/Networking/SyncQueue.swift")
        let library = try read("Sources/ViewModels/LibraryViewModel.swift")
        #expect(queue.components(separatedBy: "SyncRules.queuedFate(").count - 1 == 1)
        #expect(library.components(separatedBy: "SyncRules.queuedFate(").count - 1 == 1)
        #expect(library.contains("if let q = queued[item.id],\n           SyncRules.queuedFate("))
        let rules = try read("Sources/Models/SyncRules.swift")
        #expect(!rules.contains("shouldDropQueuedUpdate"), "a second rule for queued states is back")
    }
}
#endif
