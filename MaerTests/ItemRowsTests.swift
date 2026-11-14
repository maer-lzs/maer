// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// The keys one per title that stay on the device live in rows: the jump
/// rings and the offline copy of the bookmarks move once, a key that does
/// not read stays with a line, one entry changes without touching the
/// others, and no source reads them in the defaults. With them the finding
/// on the documents: a body that is no text never leaves without a word.
@MainActor
struct ItemRowsTests {
    private func place() throws -> (UserDefaults, String, String) {
        let suite = "item-rows-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("item-rows-\(UUID().uuidString).sqlite").path
        return (defaults, suite, path)
    }

    @Test("the jumps and the bookmarks per title move once into rows; a key that does not read stays")
    func theKeysPerTitleMove() async throws {
        let (defaults, suite, path) = try place()
        defer { defaults.removePersistentDomain(forName: suite) }
        let mark = ABSBookmark(libraryItemId: "li_a", title: "Kapitel", time: 90, createdAt: 1)
        defaults.set([[1.0, 2, 3, 4, 5, 6]], forKey: AppStorageKeys.jumpRing("li_a"))
        defaults.set([[7.0, 8, 9, 10, 11, 12]], forKey: AppStorageKeys.jumpRing("rss:f:e"))
        defaults.set("kein Ring", forKey: AppStorageKeys.jumpRing("li_broken"))
        defaults.set(try JSONEncoder().encode([mark]), forKey: "bookmarkCache.li_a")

        let database = MaerDatabase(path: path)
        let rings = JumpRingRows(spec: .jumpRings, database: database, defaults: defaults)
        let bookmarks = BookmarkCacheRows(spec: .bookmarks, database: database, defaults: defaults)
        let owner = CarrierRowsSpec.entryOwner
        #expect(rings.entry(owner, "li_a") == [[1.0, 2, 3, 4, 5, 6]])
        #expect(rings.entry(owner, "rss:f:e") == [[7.0, 8, 9, 10, 11, 12]])
        #expect(rings.entry(owner, "li_broken") == nil)
        #expect(bookmarks.entry(owner, "li_a") == [mark])
        await rings.awaitPendingWrites()
        await bookmarks.awaitPendingWrites()
        #expect(defaults.object(forKey: AppStorageKeys.jumpRing("li_a")) == nil, "the old key stayed")
        #expect(defaults.object(forKey: "bookmarkCache.li_a") == nil, "the old key stayed")
        #expect(defaults.string(forKey: AppStorageKeys.jumpRing("li_broken")) == "kein Ring", "a key that does not read left without being read")
        #expect(defaults.bool(forKey: JumpRingRows.movedKey) && defaults.bool(forKey: BookmarkCacheRows.movedKey))

        let later = JumpRingRows(spec: .jumpRings, database: database, defaults: defaults)
        #expect(later.entry(owner, "li_a") == [[1.0, 2, 3, 4, 5, 6]], "the next start reads the rows")
    }

    @Test("one entry changes without touching the others; the last one goes")
    func oneEntryChangesAlone() async throws {
        let (defaults, suite, path) = try place()
        defer { defaults.removePersistentDomain(forName: suite) }
        let rings = JumpRingRows(spec: .jumpRings, database: MaerDatabase(path: path), defaults: defaults)
        let owner = CarrierRowsSpec.entryOwner
        rings.setEntry(owner, "a", [[1]])
        rings.setEntry(owner, "b", [[2]])
        rings.setEntry(owner, "a", [[1], [3]])
        rings.removeEntries(owner) { $0 == "b" }
        await rings.awaitPendingWrites()
        let reader = try #require(try MaerDatabase(path: path).readerNow())
        let stored = try KeyedRowStore<[[Double]]>.loadNow(table: .itemJumpRing, reader: reader).rows
        #expect(stored == [JumpRingRows.key(owner, "a"): [[1], [3]]], "\(stored)")
        rings.setEntry(owner, "a", nil)
        await rings.awaitPendingWrites()
        let emptied = try KeyedRowStore<[[Double]]>.loadNow(table: .itemJumpRing, reader: try #require(try MaerDatabase(path: path).readerNow())).rows
        #expect(emptied.isEmpty, "the last entry did not go")
    }

    @Test("a body that is no text leaves the row before it in place, and in the move it stays where it is")
    func aBodyThatIsNoTextNeverLeavesSilently() async throws {
        let (defaults, suite, path) = try place()
        defer { defaults.removePersistentDomain(forName: suite) }
        let notText = Data([0xFF, 0xFE, 0xFD])
        defaults.set(notText, forKey: "maerSyncChoices")
        let documents = CarrierDocumentRows(database: MaerDatabase(path: path), defaults: defaults)
        #expect(documents.body("maerSyncChoices") == nil)
        await documents.awaitPendingWrites()
        #expect(defaults.data(forKey: "maerSyncChoices") == notText, "the move dropped a body that is no text")

        let body = Data(#"{"entries":{}}"#.utf8)
        documents.setBody("maerSyncPlaylists", body)
        documents.setBody("maerSyncPlaylists", notText)
        await documents.awaitPendingWrites()
        #expect(documents.body("maerSyncPlaylists") == body, "a body that is no text removed the row before")
    }

    @Test("no source reads jumps or bookmarks per title in the defaults", .needsTheSources)
    func noSourceReadsTheKeysPerTitle() throws {
        let sources = SourceTree.root.appendingPathComponent("Sources")
        var named: [String] = []
        for file in SourceTree.files(under: sources) where file.pathExtension == "swift" {
            let code = SyncContractFenceTests.stripped(try String(contentsOf: file, encoding: .utf8))
            if code.contains("AppStorageKeys.jumpRing(") || code.contains("\"bookmarkCache.\"") || code.contains("\"jumpRing.\"") {
                named.append(file.lastPathComponent)
            }
        }
        // The move names the old prefixes; the catalog keeps the class of
        // the old keys for the builds before.
        #expect(Set(named) == ["CarrierRows.swift", "UserChoiceSync.swift"], "the keys per title are read elsewhere: \(named.sorted())")
    }
}
#endif
