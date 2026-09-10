// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// A document set aside after its rows were written is renamed, never
/// deleted, and it leaves the backup: megabytes the rows now hold have no
/// business travelling with every backup until the release after next
/// removes them.
struct DocumentMigrationTests {
    private func fresh(_ name: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("migration-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(name)
        try Data("document".utf8).write(to: url)
        return url
    }

    @Test("beiseitegelegt heisst umbenannt, nie geloescht, und vom Backup ausgeschlossen")
    func setAsideRenamesAndExcludesFromBackup() throws {
        let document = try fresh("library_cache.json")
        defer { try? FileManager.default.removeItem(at: document.deletingLastPathComponent()) }
        try DocumentMigration.setAside(document)
        let aside = document.appendingPathExtension("migrated")
        #expect(!FileManager.default.fileExists(atPath: document.path))
        #expect(FileManager.default.fileExists(atPath: aside.path))
        #expect(try Data(contentsOf: aside) == Data("document".utf8), "the bytes are kept, a wrong move is a rename back")
        #expect(DocumentMigration.isExcludedFromBackup(aside), "the set-aside document leaves the backup")
        #expect(!DocumentMigration.isExcludedFromBackup(document.deletingLastPathComponent()), "the witness can tell the difference")
    }

    @Test("ein aelteres .migrated weicht dem neueren Dokument")
    func anEarlierAsideGivesWay() throws {
        let document = try fresh("stats.json")
        defer { try? FileManager.default.removeItem(at: document.deletingLastPathComponent()) }
        try DocumentMigration.setAside(document)
        try Data("newer".utf8).write(to: document)
        try DocumentMigration.setAside(document)
        let aside = document.appendingPathExtension("migrated")
        #expect(try Data(contentsOf: aside) == Data("newer".utf8))
        #expect(DocumentMigration.isExcludedFromBackup(aside))
    }
}
#endif
