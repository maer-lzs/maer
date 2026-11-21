// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// A chain from a card outside the loaded lists keeps the card's stand, and
/// the stored entry of a title has one reader.
@MainActor
struct CleanupThreeTests {
    @Test("a chain asked from a card outside the loaded lists starts at the card's stand; the player's position still comes first")
    func theCardsStand() {
        let nothing = BookChapterSource(playing: { nil }, listed: { _ in nil }, listedPosition: { _ in nil },
                                        fetch: { _ in throw URLError(.notConnectedToInternet) }, changed: {})
        #expect(nothing.position(of: "li_book-1", known: 900) == 900, "the card's stand was lost")
        #expect(nothing.position(of: "li_book-1", known: nil) == 0)
        let held = BookChapterSource(playing: { ("li_book-1", [], 1500) }, listed: { _ in nil },
                                     listedPosition: { _ in nil },
                                     fetch: { _ in throw URLError(.notConnectedToInternet) }, changed: {})
        #expect(held.position(of: "li_book-1", known: 900) == 1500)
    }

    @Test("the stored entry of a title is read in one place, and a view asks it there", .needsTheSources)
    func oneReaderOfTheEntry() throws {
        var readers: [String] = []
        for file in ProjectFileIntegrityTests.sourceFiles() where file.lastPathComponent != "ListeningStore.swift" {
            // The one form `storedEntry` answers: the backup, else the
            // flushed entry. A reader that tells the two apart (the start
            // of the player, the progress report) reads each on its own.
            let text = SyncContractFenceTests.stripped(try SourceTree.text(file))
                .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
                .replacingOccurrences(of: "(", with: "").replacingOccurrences(of: ")", with: "")
            if text.contains("?? ListeningStore.flushed") {
                readers.append(file.lastPathComponent)
            }
        }
        #expect(readers.isEmpty, "the backup, else the flushed entry, is read on its own in \(readers)")
        // Every other form of the same read goes through the flushed entry
        // too: each reader of it outside the store tells the two apart,
        // with why. A new one is a new reader of the entry.
        let tellApart: [String: String] = [
            "LibraryViewModel.swift": "the row Continue asks whether the flushed entry says started",
            "PlayerViewModel.swift": "the start of the player weighs the flushed entry against the server",
            "PlayerViewModel+Sync.swift": "the guard against its own echo knows the flushed time",
            "BookProgressReport.swift": "the report names the backup and the flushed entry apart",
        ]
        var flushedReaders: Set<String> = []
        for file in ProjectFileIntegrityTests.sourceFiles() where file.lastPathComponent != "ListeningStore.swift" {
            if SyncContractFenceTests.stripped(try SourceTree.text(file)).contains("ListeningStore.flushed(") {
                flushedReaders.insert(file.lastPathComponent)
            }
        }
        #expect(flushedReaders == Set(tellApart.keys), "readers of the flushed entry: \(flushedReaders.sorted())")
        let menu = SyncContractFenceTests.stripped(
            try String(contentsOf: SourceTree.root.appendingPathComponent("Sources/Views/TabContentLayout.swift"), encoding: .utf8))
        #expect(menu.contains("ListeningStore.storedEntry("), "the catalog's menu reads the entry on its own")
        let card = SyncContractFenceTests.stripped(
            try String(contentsOf: SourceTree.root.appendingPathComponent("Sources/Views/BookGridComponents.swift"), encoding: .utf8))
        #expect(card.contains("known: entry.progress?.currentTime"), "the book's card does not hand its stand to the chain")
    }
}
#endif
