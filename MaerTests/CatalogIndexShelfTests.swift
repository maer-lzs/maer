// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
import Synchronization
import OSLog
@testable import Maer

/// The rows of the free catalogues built from the index of a Mär Sync
/// service: ordered by the popularity step of the source, cut by the same
/// rotation as before, asked at the one place every archive.org row goes
/// through; without an index the source is asked as before.
struct CatalogIndexShelfTests {
    nonisolated static func json(_ id: String, step: Int? = nil, language: String? = nil, shelves: [String] = [],
                                 licence: String? = nil, year: Int? = nil, extra: [String: Any] = [:]) -> Data {
        var object: [String: Any] = [
            "id": id, "art": "hoerbuch", "titel": "Title \(id)", "urheber": "Author",
            "sprache": language.map { $0 as Any } ?? NSNull(), "jahr": year.map { $0 as Any } ?? NSNull(),
            "rechte": ["kennung": licence == nil ? "unbekannt" : "pd", "url": licence.map { $0 as Any } ?? NSNull()] as [String: Any],
            "laden": true, "reihen": shelves, "auch": [String](), "tief": NSNull()]
        if let step { object["beliebt_stufe"] = step }
        for (key, value) in extra { object[key] = value }
        return try! JSONSerialization.data(withJSONObject: object)
    }

    nonisolated static func entries(_ rows: [Data]) -> [CatalogIndexShelf.Entry] {
        rows.compactMap { CatalogIndexShelf.entry($0) }
    }

    @Test("rows with a step stand before rows without one, the lower step first, then in the order of the id")
    func order() {
        let ordered = CatalogIndexShelf.ordered(Self.entries([
            Self.json("lva:d", step: 3), Self.json("lva:c", step: 1), Self.json("lva:a"), Self.json("lva:b", step: 1)]))
        #expect(ordered.map(\.id) == ["lva:b", "lva:c", "lva:d", "lva:a"])
    }

    @Test("the vector of the service: a row with a step before the row without one", .needsTheSources)
    func vector() throws {
        let url = SourceTree.root.appendingPathComponent("MaerTests/Fixtures/MaerSyncCatalog/wege.json")
        let object = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let cases = try #require(object["faelle"] as? [[String: Any]])
        let full = try #require(cases.first { ($0["name"] as? String)?.hasPrefix("full state") == true })
        let body = try #require((full["erwartet"] as? [String: Any])?["koerper"] as? [String: Any])
        let rows = try #require(body["zeilen"] as? [[String: Any]]).map { try! JSONSerialization.data(withJSONObject: $0) }
        let ordered = CatalogIndexShelf.ordered(Self.entries(rows.reversed()))
        #expect(ordered.map(\.id) == ["lva:item-a", "lva:item-b"])
        #expect(ordered.map(\.step) == [1, nil])
    }

    @Test("the page the caller reckons is cut from the order, the total is the count of matching rows")
    func rotation() {
        let rows = (0..<40).map { Self.json(String(format: "lva:%02d", $0), step: 1) }
        let ordered = CatalogIndexShelf.ordered(Self.entries(rows))
        let answer = CatalogIndexShelf.answer(ordered, target: .init(source: "librivox", shelf: nil, languages: []), rows: 12, page: 2)
        #expect(answer.docs.compactMap(\.identifier) == (12..<24).map { String(format: "%02d", $0) })
        #expect(answer.total == 40)
    }

    @Test("each archive.org question of a row names its source and shelf; a question of a genre names none")
    func targets() throws {
        let books = try #require(ArchiveOrgClient.archiveBaseQuery(for: .archiveBooks))
        let german = try #require(FreeCatalog.archiveLanguageClause(codes: ["de"]))
        #expect(CatalogIndexShelf.target(query: "collection:librivoxaudio AND mediatype:(audio)")
                == .init(source: "librivox", shelf: nil, languages: []))
        #expect(CatalogIndexShelf.target(query: "collection:librivoxaudio AND \(german)")?.source == "librivox")
        #expect(CatalogIndexShelf.target(query: "collection:librivoxaudio AND \(german)")?.languages.isEmpty == false)
        #expect(CatalogIndexShelf.target(query: books)?.source == "archive-buch")
        #expect(CatalogIndexShelf.target(query: books + " AND \(german)")?.source == "archive-buch")
        #expect(CatalogIndexShelf.target(query: ArchiveOrgClient.oldTimeRadioQuery)?.source == "otr")
        #expect(CatalogIndexShelf.target(query: ArchiveMusicCatalog.netlabels.query) == .init(source: "netlabel", shelf: nil, languages: []))
        #expect(CatalogIndexShelf.target(query: ArchiveMusicCatalog.classical.query) == .init(source: "schellack", shelf: "free-classical", languages: []))
        #expect(CatalogIndexShelf.target(query: ArchiveMusicCatalog.shellacAll.query) == .init(source: "schellack", shelf: nil, languages: []))
        #expect(CatalogIndexShelf.target(query: "collection:librivoxaudio AND subject:\"poetry\"") == nil)
    }

    @Test("a shelf takes only its rows, a language only rows in it")
    func shelfAndLanguage() throws {
        let ordered = CatalogIndexShelf.ordered(Self.entries([
            Self.json("lva:jazz", step: 1, language: "English", shelves: ["shellac-jazz"]),
            Self.json("lva:opera", step: 1, language: "German", shelves: ["shellac-opera"])]))
        let jazz = CatalogIndexShelf.answer(ordered, target: .init(source: "schellack", shelf: "shellac-jazz", languages: []), rows: 12, page: 1)
        #expect(jazz.docs.compactMap(\.identifier) == ["jazz"])
        let target = try #require(CatalogIndexShelf.target(query: "collection:librivoxaudio AND " + FreeCatalog.archiveLanguageClause(codes: ["de"])!))
        let german = CatalogIndexShelf.answer(CatalogIndexShelf.ordered(Self.entries([
            Self.json("lva:de", step: 2, language: "deu"), Self.json("lva:en", step: 1, language: "eng")])), target: target, rows: 12, page: 1)
        #expect(german.docs.compactMap(\.identifier) == ["de"])
    }

    @Test("a row becomes an entry like archive.org's: id without the prefix, licence, year, the collection of its source")
    func doc() throws {
        let entry = try #require(CatalogIndexShelf.entry(Self.json("lva:item", step: 1, licence: "http://creativecommons.org/licenses/by/3.0/", year: 1925,
                                                                   extra: ["neu": "unknown field"])))
        let doc = CatalogIndexShelf.doc(entry, source: "netlabel")
        #expect(doc.identifier == "item")
        #expect(doc.title?.first == "Title lva:item")
        #expect(doc.creator?.first == "Author")
        #expect(doc.licenseurl == "http://creativecommons.org/licenses/by/3.0/")
        #expect(doc.year?.first == "1925")
        #expect(doc.collection?.first == "netlabels")
        #expect(CatalogIndexShelf.doc(entry, source: "schellack").collection?.first == "georgeblood")
    }

    @Test("a row with laden false is never kept on the device, even with a stated licence; with laden true the licence decides as before")
    @MainActor func ladenFalseIsNeverKept() throws {
        let barred = try #require(CatalogIndexShelf.entry(Self.json("lva:index-laden-false", step: 1, licence: "http://creativecommons.org/licenses/by/3.0/",
                                                                    extra: ["laden": false])))
        let barredItem = try #require(FreeCatalogProvider.shared.remember(popular: CatalogIndexShelf.doc(barred, source: "schellack")))
        #expect(!FreeCatalogProvider.shared.mayKeep(itemId: barredItem.id), "a row the service bars from the library may be downloaded")
        let free = try #require(CatalogIndexShelf.entry(Self.json("lva:index-laden-true", step: 1, licence: "http://creativecommons.org/licenses/by/3.0/")))
        let freeItem = try #require(FreeCatalogProvider.shared.remember(popular: CatalogIndexShelf.doc(free, source: "netlabel")))
        #expect(FreeCatalogProvider.shared.mayKeep(itemId: freeItem.id))
    }

    nonisolated final class Reads: Sendable {
        let count = Mutex(0)
        let version = Mutex(1)
        let rows: [Data]
        init(_ rows: [Data]) { self.rows = rows }
        var read: CatalogIndexShelfReader.Read {
            { source in
                self.count.withLock { $0 += 1 }
                return source == "netlabel" ? (version: self.version.withLock { $0 }, rows: self.rows) : nil
            }
        }
    }

    @Test("at the one place: an index with rows answers the netlabels without the network; read once per version")
    func atThePlace() async throws {
        let reads = Reads([Self.json("lva:net-b", step: 2), Self.json("lva:net-a", step: 1)])
        let reader = CatalogIndexShelfReader(read: reads.read)
        let answer = try await ArchiveOrgClient.popularWithTotal(query: ArchiveMusicCatalog.netlabels.query, rows: 12, page: 1, index: reader)
        #expect(answer.docs.compactMap(\.identifier) == ["net-a", "net-b"])
        #expect(answer.total == 2)
        _ = await reader.answer(query: ArchiveMusicCatalog.netlabels.query, rows: 12, page: 1)
        #expect(await reader.parsed == 1, "the same version is parsed again")
        reads.version.withLock { $0 = 2 }
        _ = await reader.answer(query: ArchiveMusicCatalog.netlabels.query, rows: 12, page: 1)
        #expect(await reader.parsed == 2, "a new version is not read")
    }

    @Test("without an index, with version 0 or another sort the index gives no answer")
    func withoutIndex() async {
        let empty = CatalogIndexShelfReader(read: { _ in nil })
        #expect(await empty.answer(query: ArchiveMusicCatalog.netlabels.query, rows: 12, page: 1) == nil)
        let none = CatalogIndexShelfReader(read: { _ in (version: 0, rows: []) })
        #expect(await none.answer(query: ArchiveMusicCatalog.netlabels.query, rows: 12, page: 1) == nil)
        let reads = Reads([Self.json("lva:net-a", step: 1)])
        let reader = CatalogIndexShelfReader(read: reads.read)
        #expect(await reader.answer(query: "collection:librivoxaudio AND subject:\"poetry\"", rows: 12, page: 1) == nil)
    }

    @Test("a row of the index that is not JSON is passed over with a log line naming its source and its reason; the rows beside it stand")
    func aRowNotJSONIsLogged() async throws {
        let since = Date()
        let reader = CatalogIndexShelfReader(read: { _ in (version: 1, rows: [Data("{kaputt".utf8), Self.json("lva:net-a", step: 1)]) })
        let answer = await reader.answer(query: ArchiveMusicCatalog.netlabels.query, rows: 12, page: 1)
        #expect(answer?.docs.compactMap(\.identifier) == ["net-a"])
        let logStore = try OSLogStore(scope: .currentProcessIdentifier)
        let lines = try logStore.getEntries(at: logStore.position(date: since)).compactMap { $0 as? OSLogEntryLog }
            .filter { $0.subsystem == AppLogSubsystem.value && $0.category == "library" }
            .map(\.composedMessage).filter { $0.hasPrefix("CATALOG index netlabel row passed over") }
        #expect(lines.count == 1 && lines.first?.contains("reason=") == true, "the line: \(lines)")
    }

    @Test("a page behind the end of the index, or a shelf it holds no row of, goes to archive.org instead of an empty row")
    func behindTheEnd() async {
        let reads = Reads((0..<20).map { Self.json(String(format: "lva:%02d", $0), step: 1) })
        let reader = CatalogIndexShelfReader(read: reads.read)
        #expect(await reader.answer(query: ArchiveMusicCatalog.netlabels.query, rows: 12, page: 2)?.docs.count == 8)
        #expect(await reader.answer(query: ArchiveMusicCatalog.netlabels.query, rows: 12, page: 300) == nil)
        let shelves = CatalogIndexShelfReader(read: { _ in (version: 1, rows: [Self.json("lva:jazz", step: 1, shelves: ["shellac-jazz"])]) })
        #expect(await shelves.answer(query: ArchiveMusicCatalog.classical.query, rows: 12, page: 1) == nil)
    }

    @Test("Fence: the archive.org question asks the index first, only for the popularity order", .needsTheSources)
    func fence() throws {
        let text = SyncContractFenceTests.stripped(try String(contentsOf: SourceTree.root.appendingPathComponent("Sources/Networking/FreeCatalogClients.swift"), encoding: .utf8))
        let start = try #require(text.range(of: "static func popularWithTotal("))
        let body = text[start.upperBound...].prefix(700)
        let asked = try #require(body.range(of: "await index.answer(query: query, rows: rows, page: page)"))
        let built = try #require(body.range(of: "URLComponents(string:"))
        #expect(asked.lowerBound < built.lowerBound)
        #expect(body.contains("sort == ArchiveOrgClient.popularitySort"))
    }

    @Test("the contract is the text with the rule and the popularity step", .needsTheSources)
    func contract() throws {
        let text = try String(contentsOf: SourceTree.root.appendingPathComponent("docs/maer-sync-contract.md"), encoding: .utf8)
        #expect(text.contains("`beliebt_stufe`"))
        #expect(text.contains("## Always backwards compatible"))
        #expect(try SyncContractFenceTests.contractDigest(in: SourceTree.root).hasPrefix("109620ba364d"))
    }
}
#endif
