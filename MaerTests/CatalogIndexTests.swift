// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
import Synchronization
@testable import Maer

/// The catalogue index of a Mär Sync service (addition katalog-1 to
/// contract version 6), read by this device: the full state page by page,
/// later the delta, kept in its own tables; an answer that is not a whole
/// page walk takes nothing over, and unknown never becomes empty.
struct CatalogIndexTests {
    /// A row as the service sends it (the shape of the vectors of the
    /// service, `archive-buch/normal`).
    nonisolated static func row(_ id: String, title: String = "T", deleted: Bool = false) -> MaerSyncCatalogRow {
        let object: [String: Any] = deleted ? ["id": id, "geloescht": true] : [
            "quelle": "archive-buch", "id": id, "art": "hoerbuch", "titel": title, "urheber": NSNull(),
            "sprache": NSNull(), "jahr": NSNull(), "rechte": ["kennung": "pd", "url": NSNull()], "laden": true,
            "reihen": [String](), "auch": [String](), "tief": NSNull(), "geloescht": false]
        return MaerSyncCatalogRow(id: id, deleted: deleted, json: try! JSONSerialization.data(withJSONObject: object))
    }

    nonisolated static func page(version: Int, _ rows: [MaerSyncCatalogRow], next: String?, format: Int = 1) -> MaerSyncCatalogAnswer {
        .page(MaerSyncCatalogPage(format: format, source: "archive-buch", version: version, rows: rows, next: next,
                                  etag: "\"\(format)-archive-buch-\(version)\""))
    }

    /// A service in the test: answers by the query, records every query.
    nonisolated final class Service: @unchecked Sendable {
        // Unchecked because the lock guards the asked queries and the answer.
        let lock = NSLock()
        var asked: [MaerSyncCatalogQuery] = []
        var answer: (MaerSyncCatalogQuery) throws -> MaerSyncCatalogAnswer
        init(_ answer: @escaping (MaerSyncCatalogQuery) throws -> MaerSyncCatalogAnswer) { self.answer = answer }
        var ask: CatalogIndexRun.Ask {
            { query in try self.lock.withLock { self.asked.append(query); return try self.answer(query) } }
        }
    }

    static func store() async throws -> CatalogRowStore {
        try await CatalogRowStore(connection: SQLiteConnection(path: ":memory:"))
    }

    @Test("the full state in two pages: every row in the index, the version kept")
    func fullTwoPages() async throws {
        let store = try await Self.store()
        let service = Service { query in
            query.after == nil ? Self.page(version: 3, [Self.row("lva:a"), Self.row("lva:b")], next: "lva:b")
                               : Self.page(version: 3, [Self.row("lva:c")], next: nil)
        }
        let outcome = await CatalogIndexRun.run(.archiveBuch, store: store, ask: service.ask, pageSize: 2, nowMs: 1)
        #expect(outcome == .taken(version: 3))
        #expect(try await store.indexRows("archive-buch").keys.sorted() == ["lva:a", "lva:b", "lva:c"])
        #expect(try await store.indexState("archive-buch")?.version == 3)
        #expect(service.asked.map(\.after) == [nil, "lva:b"])
        #expect(service.asked.allSatisfy { $0.count == 2 && $0.since == nil })
    }

    @Test("a version that changes between two pages starts the walk again, and the whole new version is taken")
    func versionChanges() async throws {
        let store = try await Self.store()
        let calls = Mutex(0)
        let service = Service { query in
            let call = calls.withLock { $0 += 1; return $0 }
            if call == 1 { return Self.page(version: 3, [Self.row("lva:a")], next: "lva:a") }
            return query.after == nil ? Self.page(version: 4, [Self.row("lva:a")], next: "lva:a")
                                      : Self.page(version: 4, [Self.row("lva:z")], next: nil)
        }
        #expect(await CatalogIndexRun.run(.archiveBuch, store: store, ask: service.ask, pageSize: 1, nowMs: 1) == .taken(version: 4))
        #expect(try await store.indexRows("archive-buch").keys.sorted() == ["lva:a", "lva:z"])
    }

    @Test("the delta: a living row changes, a deletion mark removes, the version follows")
    func delta() async throws {
        let store = try await Self.store()
        try await store.takeFull("archive-buch", rows: [Self.row("lva:a"), Self.row("lva:b"), Self.row("lva:c")],
                                 version: 3, etag: nil, etagAddress: nil, atMs: 1)
        let service = Service { query in
            #expect(query.since == 3)
            return Self.page(version: 5, [Self.row("lva:b", title: "neu"), Self.row("lva:c", deleted: true)], next: nil)
        }
        #expect(await CatalogIndexRun.run(.archiveBuch, store: store, ask: service.ask, nowMs: 2) == .taken(version: 5))
        let rows = try await store.indexRows("archive-buch")
        #expect(rows.keys.sorted() == ["lva:a", "lva:b"])
        #expect(String(decoding: try #require(rows["lva:b"]), as: UTF8.self).contains("neu"))
        #expect(try await store.indexState("archive-buch")?.version == 5)
    }

    @Test("304: the tag goes back only with its own address, and nothing changes")
    func unchanged() async throws {
        let store = try await Self.store()
        let first = Service { _ in Self.page(version: 5, [], next: nil) }
        try await store.takeFull("archive-buch", rows: [Self.row("lva:a")], version: 5, etag: nil, etagAddress: nil, atMs: 1)
        _ = await CatalogIndexRun.run(.archiveBuch, store: store, ask: first.ask, nowMs: 2)
        let second = Service { query in query.ifNoneMatch == "\"1-archive-buch-5\"" ? .unchanged : Self.page(version: 5, [], next: nil) }
        #expect(await CatalogIndexRun.run(.archiveBuch, store: store, ask: second.ask, nowMs: 3) == .unchanged)
        #expect(second.asked.first?.ifNoneMatch == "\"1-archive-buch-5\"", "the tag of the same address was not sent back")
        #expect(try await store.indexRows("archive-buch").keys.sorted() == ["lva:a"])
    }

    @Test("410 on the delta: the full state is read and taken")
    func goneReadsFull() async throws {
        let store = try await Self.store()
        try await store.takeFull("archive-buch", rows: [Self.row("lva:old")], version: 1, etag: nil, etagAddress: nil, atMs: 1)
        let service = Service { query in query.since != nil ? .gone : Self.page(version: 9, [Self.row("lva:new")], next: nil) }
        #expect(await CatalogIndexRun.run(.archiveBuch, store: store, ask: service.ask, nowMs: 2) == .taken(version: 9))
        #expect(try await store.indexRows("archive-buch").keys.sorted() == ["lva:new"])
    }

    @Test("404: the service carries no catalogue; nothing changes")
    func noCatalog() async throws {
        let store = try await Self.store()
        try await store.takeFull("archive-buch", rows: [Self.row("lva:a")], version: 2, etag: nil, etagAddress: nil, atMs: 1)
        let service = Service { _ in .absent }
        #expect(await CatalogIndexRun.run(.archiveBuch, store: store, ask: service.ask, nowMs: 2) == .noCatalog)
        #expect(try await store.indexRows("archive-buch").keys.sorted() == ["lva:a"])
    }

    @Test("503 with Retry-After: the state stays, and the source is not asked again before the time")
    func busy() async throws {
        let store = try await Self.store()
        try await store.takeFull("archive-buch", rows: [Self.row("lva:a")], version: 2, etag: nil, etagAddress: nil, atMs: 1)
        let service = Service { _ in .busy(retryAfter: 120) }
        let now = 100_000_000.0
        #expect(await CatalogIndexRun.run(.archiveBuch, store: store, ask: service.ask, nowMs: now) == .later(retryAfter: 120))
        #expect(try await store.indexRows("archive-buch").keys.sorted() == ["lva:a"])
        let state = try await store.indexState("archive-buch")
        #expect(!CatalogIndexRun.isDue(state, nowMs: now + 60_000))
    }

    @Test("an unknown format and a version 0 take nothing over")
    func nothingTaken() async throws {
        let store = try await Self.store()
        try await store.takeFull("archive-buch", rows: [Self.row("lva:a")], version: 2, etag: nil, etagAddress: nil, atMs: 1)
        let unknown = Service { _ in Self.page(version: 7, [Self.row("lva:x")], next: nil, format: 2) }
        if case .nothingTaken = await CatalogIndexRun.run(.archiveBuch, store: store, ask: unknown.ask, nowMs: 2) {} else {
            Issue.record("an unknown format was taken")
        }
        let fresh = try await Self.store()
        let zero = Service { _ in Self.page(version: 0, [], next: nil) }
        if case .nothingTaken = await CatalogIndexRun.run(.archiveBuch, store: fresh, ask: zero.ask, nowMs: 2) {} else {
            Issue.record("version 0 was taken as an empty source")
        }
        #expect(try await store.indexRows("archive-buch").keys.sorted() == ["lva:a"])
        #expect(try await fresh.indexState("archive-buch") == nil)
    }

    @Test("a walk that breaks after the first page takes nothing")
    func halfWalk() async throws {
        let store = try await Self.store()
        let service = Service { query in
            if query.after == nil { return Self.page(version: 3, [Self.row("lva:a")], next: "lva:a") }
            throw URLError(.timedOut)
        }
        if case .nothingTaken = await CatalogIndexRun.run(.archiveBuch, store: store, ask: service.ask, pageSize: 1, nowMs: 1) {} else {
            Issue.record("a half walk was taken")
        }
        #expect(try await store.indexRows("archive-buch").isEmpty)
    }

    @Test("once a day per source")
    func oncePerDay() {
        let state = CatalogRowStore.IndexState(version: 3, etag: nil, etagAddress: nil, readAtMs: 0, notBeforeMs: nil)
        #expect(!CatalogIndexRun.isDue(state, nowMs: 23 * 3_600_000))
        #expect(CatalogIndexRun.isDue(state, nowMs: 25 * 3_600_000))
        #expect(CatalogIndexRun.isDue(nil, nowMs: 0))
    }

    @Test("the one place turns every status into an answer; 401 and 426 go as with a document")
    func answers() throws {
        func reply(_ status: Int, _ headers: [String: String] = [:], _ body: String = "") -> MaerSyncReply {
            MaerSyncReply(status: status, lowercasedHeaders: headers, body: Data(body.utf8))
        }
        let body = #"{"katalog_format":1,"quelle":"archive-buch","version":3,"zeilen":[{"id":"lva:a","titel":"T","geloescht":false},{"id":"lva:b","geloescht":true}],"weiter":null}"#
        guard case .page(let page) = try MaerSyncAnswer.catalog(reply(200, ["etag": "\"1-archive-buch-3\""], body)) else {
            Issue.record("200 is no page"); return
        }
        #expect(page.version == 3 && page.next == nil && page.etag == "\"1-archive-buch-3\"")
        #expect(page.rows.map(\.id) == ["lva:a", "lva:b"] && page.rows.map(\.deleted) == [false, true])
        #expect(try MaerSyncAnswer.catalog(reply(304)) == .unchanged)
        #expect(try MaerSyncAnswer.catalog(reply(404)) == .absent)
        #expect(try MaerSyncAnswer.catalog(reply(410)) == .gone)
        #expect(try MaerSyncAnswer.catalog(reply(400)) == .refused(400))
        #expect(try MaerSyncAnswer.catalog(reply(503, ["retry-after": "120"])) == .busy(retryAfter: 120))
        #expect(try MaerSyncAnswer.catalog(reply(502)) == .busy(retryAfter: nil))
        #expect(throws: MaerSyncFailure.self) { try MaerSyncAnswer.catalog(reply(401)) }
        #expect(throws: MaerSyncFailure.self) { try MaerSyncAnswer.catalog(reply(426)) }
    }

    @Test("the sources read follow the switches of the app")
    @MainActor func sources() {
        var gates = CatalogLoaderWitness.allOn
        gates.musopen = true
        #expect(Set(CatalogIndexRun.sources(gates)) == Set(CatalogIndexSource.allCases))
        gates.archiveBooks = false
        #expect(Set(CatalogIndexRun.sources(gates)) == [.librivox, .gutenberg, .musopen])
    }

    @Test("Fence: the door reads the catalogue through the one helper that carries the token", .needsTheSources)
    func door() throws {
        let client = SyncContractFenceTests.stripped(try String(contentsOf: SourceTree.root.appendingPathComponent("Sources/Networking/MaerSyncClient.swift"), encoding: .utf8))
        #expect(client.contains("MaerSyncAnswer.catalog(\n            try await inside(access, \"GET\", MaerSyncPaths.catalog("))
        #expect(client.contains("\"v1/katalog/"))
    }
}
#endif
