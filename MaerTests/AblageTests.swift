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
        // A real state is a genuine recovery and passes; the block lifts.
        try await ablage.save(Doc(items: [1]), name: "doc.json")
        #expect(await ablage.load(Doc.self, name: "doc.json").value == Doc(items: [1]))
        try await ablage.save(Doc(items: []), name: "doc.json", isEmpty: true)
        #expect(await ablage.load(Doc.self, name: "doc.json").value == Doc(items: []))
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
