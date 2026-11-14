// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// Data the app can fetch again stays out of backups, marked on its
/// directory through ONE function: downloads, kept covers, catalogue stocks.
struct BackupExclusionTests {
    @Test("a marked store carries the mark on the disk, another one does not")
    func aMarkedDirectoryCarriesTheMark() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("backup-\(UUID().uuidString)", isDirectory: true)
        let marked = root.appendingPathComponent("marked", isDirectory: true)
        let plain = root.appendingPathComponent("plain", isDirectory: true)
        for dir in [marked, plain] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(!BackupExclusion.isMarked(marked), "a fresh directory is marked already, the case measures nothing")
        #expect(BackupExclusion.mark(marked, label: "witness"))
        #expect(BackupExclusion.isMarked(marked))
        #expect(!BackupExclusion.isMarked(plain))
        #expect(!BackupExclusion.mark(root.appendingPathComponent("missing", isDirectory: true), label: "witness"),
                "a directory that is not there cannot be marked, and the answer says so")
    }

    @Test("the catalog stock lies outside the backup after writing")
    func theCatalogStockStaysOutOfBackups() throws {
        let surface = "backuptest-\(UUID().uuidString)"
        let stock = CatalogStock(surface: surface, takenAt: 1, entries: [
            CatalogStockEntry(id: "a", title: "a", creator: nil, subjects: ["fiction"],
                              downloads: 1, licenseurl: nil, year: nil)])
        defer { try? FileManager.default.removeItem(at: CatalogStockStore.fileURL(surface: surface)) }
        // The directory may carry the mark from an earlier write in this
        // host; it is taken off first, so only this write can set it.
        let directory = CatalogStockStore.directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = false
        var unmarked = directory
        try unmarked.setResourceValues(values)
        try #require(!BackupExclusion.isMarked(directory), "the mark could not be taken off, the case measures nothing")
        #expect(CatalogStockStore.shared.save(stock))
        #expect(BackupExclusion.isMarked(directory), "the stock was written into a directory that goes into backups")
    }

    @Test("only the one function sets the mark", .needsTheSources)
    func onlyTheSeamSetsTheMark() {
        let files = ProjectFileIntegrityTests.sourceTexts()
        #expect(files.contains { $0.name == "BackupExclusion.swift" }, "der Zaun hat die Naht nicht gelesen")
        let setters = files.filter { $0.name != "BackupExclusion.swift" }
            .filter { SyncContractFenceTests.stripped($0.text).contains("isExcludedFromBackup") }
            .map(\.name)
        #expect(setters.isEmpty, "a directory is marked past the seam: \(setters)")
        let callers = files.filter { SyncContractFenceTests.stripped($0.text).contains("BackupExclusion.mark(") }
            .map(\.name).sorted()
        #expect(callers == ["CatalogStockStore.swift", "DownloadManager.swift", "ImageCache.swift"],
                "the three directories of fetchable data: \(callers)")
    }
}
#endif
