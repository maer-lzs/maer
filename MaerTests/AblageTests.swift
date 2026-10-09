// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// The seam's four promises: a later save wins, a reader never sees a
/// half-written file, an unreadable file is kept aside and never buried by
/// emptiness, and a failure throws instead of vanishing.
struct AblageTests {
    private nonisolated struct Doc: Codable, Equatable, Sendable { var items: [Int] }

    private func scratch() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ablage-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test("Spaeterer Schrieb gewinnt, auch wenn zwanzig auf einmal kommen; laden sieht den letzten")
    func laterSaveWins() async throws {
        let dir = scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let ablage = Ablage(directory: dir)
        for i in 1...20 {
            try await ablage.save(Doc(items: Array(repeating: i, count: 500)), name: "doc.json")
        }
        let loaded = await ablage.load(Doc.self, name: "doc.json")
        #expect(loaded.value == Doc(items: Array(repeating: 20, count: 500)))
        // Nothing but the document remains: no temporary file left behind.
        let files = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        #expect(files == ["doc.json"])
    }

    @Test("Fehlt die Datei, ist es frisch; unlesbar wandert beiseite und sperrt einen leeren Schrieb, nicht einen echten")
    func corruptIsKeptAsideAndNeverBuriedByEmptiness() async throws {
        let dir = scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let ablage = Ablage(directory: dir)
        if case .fresh = await ablage.load(Doc.self, name: "doc.json") {} else { Issue.record("missing must read as fresh") }
        try "not json".write(to: dir.appendingPathComponent("doc.json"), atomically: true, encoding: .utf8)
        if case .corrupt = await ablage.load(Doc.self, name: "doc.json") {} else { Issue.record("unreadable must read as corrupt") }
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("doc.json.corrupt").path))
        // Emptiness over the corrupt file throws; the aside file stays.
        await #expect(throws: AblageError.blockedByCorruptFile(name: "doc.json")) {
            try await ablage.save(Doc(items: []), name: "doc.json", isEmpty: true)
        }
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("doc.json.corrupt").path))
        // The second read finds no file, and it is still not "none yet".
        if case .corrupt = await ablage.load(Doc.self, name: "doc.json") {} else { Issue.record("the second read after setting aside said fresh") }
        // A real state is a genuine recovery and passes; the block lifts.
        try await ablage.save(Doc(items: [1]), name: "doc.json")
        #expect(await ablage.load(Doc.self, name: "doc.json").value == Doc(items: [1]))
        try await ablage.save(Doc(items: []), name: "doc.json", isEmpty: true)
        #expect(await ablage.load(Doc.self, name: "doc.json").value == Doc(items: []))
    }

    @Test("unlesbar bleibt unlesbar ueber einen Neustart, bis ein echter Schrieb oder eine Entfernung kommt")
    func unreadableOutlivesARestart() async throws {
        let dir = scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        // Nothing aside: fresh, and an empty save stays allowed.
        let first = Ablage(directory: dir)
        if case .fresh = await first.load(Doc.self, name: "other.json") {} else { Issue.record("missing must read as fresh") }
        try await first.save(Doc(items: []), name: "other.json", isEmpty: true)
        try "not json".write(to: dir.appendingPathComponent("doc.json"), atomically: true, encoding: .utf8)
        if case .corrupt = await Ablage(directory: dir).load(Doc.self, name: "doc.json") {} else { Issue.record("unreadable must read as corrupt") }
        // A new process: a new seam on the same folder, nothing in memory.
        let restarted = Ablage(directory: dir)
        if case .corrupt = await restarted.load(Doc.self, name: "doc.json") {} else { Issue.record("after a restart the name read as none yet") }
        if case .corrupt = Ablage(directory: dir).loadNow(Doc.self, name: "doc.json") {} else { Issue.record("the init-time read said none yet") }
        await #expect(throws: AblageError.blockedByCorruptFile(name: "doc.json")) {
            try await restarted.save(Doc(items: []), name: "doc.json", isEmpty: true)
        }
        // A removal retires the sign and keeps the file for forensics.
        try await restarted.remove(name: "doc.json")
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("doc.json.corrupt.removed").path))
        if case .fresh = await Ablage(directory: dir).load(Doc.self, name: "doc.json") {} else { Issue.record("after a removal the name stayed unreadable") }
        // A real save after a restart is a recovery, as in one process.
        try "not json".write(to: dir.appendingPathComponent("doc.json"), atomically: true, encoding: .utf8)
        _ = await Ablage(directory: dir).load(Doc.self, name: "doc.json")
        let again = Ablage(directory: dir)
        try await again.save(Doc(items: [2]), name: "doc.json")
        #expect(await Ablage(directory: dir).load(Doc.self, name: "doc.json").value == Doc(items: [2]))
    }

    /// The synchronous removal and the lever that empties the catalog stocks
    /// retire the file aside as `remove` does: the name reads as none yet
    /// afterwards, not as unreadable for ever.
    @Test("removeNow und das Leeren der Katalog-Bestaende nehmen die Beiseite-Datei mit, der Name liest sich danach als neu")
    func theSynchronousRemovalsRetireTheFileAside() async throws {
        let dir = scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try "not json".write(to: dir.appendingPathComponent("grown.json"), atomically: true, encoding: .utf8)
        if case .corrupt = Ablage(directory: dir).loadNow(Doc.self, name: "grown.json") {} else { Issue.record("the precondition: unreadable") }
        Ablage(directory: dir).removeNow(name: "grown.json")
        if case .fresh = Ablage(directory: dir).loadNow(Doc.self, name: "grown.json") {} else { Issue.record("after removeNow the name stayed unreadable") }
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("grown.json.corrupt.removed").path),
                "the file aside was not kept for forensics")
        // The lever over a folder of stocks: a stock and its file aside.
        try "not json".write(to: dir.appendingPathComponent("librivox.json"), atomically: true, encoding: .utf8)
        if case .corrupt = Ablage(directory: dir).loadNow(CatalogStock.self, name: "librivox.json") {} else { Issue.record("the precondition: unreadable stock") }
        try "{}".write(to: dir.appendingPathComponent("archive.json"), atomically: true, encoding: .utf8)
        #expect(CatalogStockStore.shared.clear(in: dir) == 1, "the lever counts the stock files it removed")
        if case .fresh = Ablage(directory: dir).loadNow(CatalogStock.self, name: "librivox.json") {} else { Issue.record("after the lever the stock stayed unreadable") }
    }

    /// A file that is there and cannot be read is no fresh start: it reads
    /// as unreadable, the empty save is refused, and it stays untouched where
    /// it is. Measured before (W-Sammel 12a): both read as fresh, and the
    /// empty save over a folder in the file's place replaced the folder.
    @Test("eine vorhandene, nicht lesbare Datei ist nie neu: sie bleibt an ihrem Platz, der leere Schrieb ist gesperrt")
    func aPresentUnreadableFileIsNeverFresh() async throws {
        let dir = scratch()
        let file = dir.appendingPathComponent("doc.json")
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)
            try? FileManager.default.removeItem(at: dir)
        }
        try JSONEncoder().encode(Doc(items: [1, 2, 3])).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: file.path)
        try #require((try? Data(contentsOf: file)) == nil, "the precondition: the file cannot be read here")
        let ablage = Ablage(directory: dir)
        if case .corrupt = await ablage.load(Doc.self, name: "doc.json") {} else { Issue.record("an unreadable file read as fresh") }
        await #expect(throws: AblageError.blockedByCorruptFile(name: "doc.json")) {
            try await ablage.save(Doc(items: []), name: "doc.json", isEmpty: true)
        }
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("doc.json.corrupt").path),
                "the unreadable file was moved, the passing cause would leave it aside for good")
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)
        #expect(await Ablage(directory: dir).load(Doc.self, name: "doc.json").value == Doc(items: [1, 2, 3]),
                "once the cause passed, the file reads whole")
        // A folder in the file's place.
        let folder = dir.appendingPathComponent("dir.json")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        if case .corrupt = Ablage(directory: dir).loadNow(Doc.self, name: "dir.json") {} else { Issue.record("a folder read as fresh") }
        let second = Ablage(directory: dir)
        _ = await second.load(Doc.self, name: "dir.json")
        await #expect(throws: AblageError.blockedByCorruptFile(name: "dir.json")) {
            try await second.save(Doc(items: []), name: "dir.json", isEmpty: true)
        }
        var isFolder: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: folder.path, isDirectory: &isFolder) && isFolder.boolValue,
                "the empty save replaced the folder")
    }

    /// Without a load before: a folder in the document's place is refused
    /// the empty save as the load would answer it, and stays.
    @Test("ohne vorheriges Laden sperrt die Sperre den leeren Schrieb ueber einem vorhandenen, unlesbaren Dokument")
    func theLockCoversAPresentUnreadableDocumentWithoutALoad() async throws {
        let dir = scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let folder = dir.appendingPathComponent("dir.json")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        await #expect(throws: AblageError.blockedByCorruptFile(name: "dir.json")) {
            try await Ablage(directory: dir).save(Doc(items: []), name: "dir.json", isEmpty: true)
        }
        var isFolder: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: folder.path, isDirectory: &isFolder) && isFolder.boolValue,
                "the empty save replaced the folder")
        // A document that reads and does not decode: the load would answer
        // `.corrupt` and keep it aside; the empty save leaves it whole.
        try "not json".write(to: dir.appendingPathComponent("doc.json"), atomically: true, encoding: .utf8)
        await #expect(throws: AblageError.blockedByCorruptFile(name: "doc.json")) {
            try await Ablage(directory: dir).save(Doc(items: []), name: "doc.json", isEmpty: true)
        }
        #expect(try String(contentsOf: dir.appendingPathComponent("doc.json"), encoding: .utf8) == "not json",
                "the empty save buried an undecodable document")
        // A readable document stays open to an empty save.
        try await Ablage(directory: dir).save(Doc(items: [5]), name: "ok.json")
        try await Ablage(directory: dir).save(Doc(items: []), name: "ok.json", isEmpty: true)
    }

    /// The lock reads the same sign as the load: a new instance that never
    /// loaded refuses the empty save over a file aside.
    @Test("die Sperre liest dasselbe Zeichen wie das Laden: ohne vorher zu laden ist der leere Schrieb ueber einer Beiseite-Datei gesperrt")
    func theLockReadsTheFileAsideWithoutALoad() async throws {
        let dir = scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        try "not json".write(to: dir.appendingPathComponent("doc.json.corrupt"), atomically: true, encoding: .utf8)
        await #expect(throws: AblageError.blockedByCorruptFile(name: "doc.json")) {
            try await Ablage(directory: dir).save(Doc(items: []), name: "doc.json", isEmpty: true)
        }
        // A real state still passes: a genuine recovery, and after it an
        // empty state is the store's own again, as the load reads it.
        try await Ablage(directory: dir).save(Doc(items: [4]), name: "doc.json")
        #expect(await Ablage(directory: dir).load(Doc.self, name: "doc.json").value == Doc(items: [4]))
        try await Ablage(directory: dir).save(Doc(items: []), name: "doc.json", isEmpty: true)
        #expect(await Ablage(directory: dir).load(Doc.self, name: "doc.json").value == Doc(items: []))
    }

    @Test("Ein Schreibfehler wirft und verschwindet nicht")
    func writeFailureThrows() async throws {
        // A FILE where the store's directory should be: no temporary file
        // can be created, the save cannot land.
        let blocker = FileManager.default.temporaryDirectory.appendingPathComponent("ablage-blocker-\(UUID().uuidString)")
        try Data("x".utf8).write(to: blocker)
        defer { try? FileManager.default.removeItem(at: blocker) }
        let ablage = Ablage(directory: blocker)
        var threw = false
        do { try await ablage.save(Doc(items: [1]), name: "doc.json") } catch { threw = true }
        #expect(threw, "a save that cannot land must throw")
        // Remove is idempotent for a missing document.
        try await ablage.remove(name: "missing.json")
    }
}
#endif
