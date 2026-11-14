// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// A stock nothing reads any more leaves the device at start: the old
/// shellac stock holds the whole 78 rpm collection past the shelves.
struct CatalogStockRetiredTests {
    @Test("the old shellac stock goes at start, finished and half, others stay")
    func theRetiredStockGoes() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("retired-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }
        let partial = "shellac-all" + CatalogStockFetch.partialSuffix
        for name in ["shellac-all.json", partial, partial + ".total", "netlabels.json",
                     ArchiveMusicCatalog.shellacAll.key + ".json"] {
            try Data("x".utf8).write(to: dir.appendingPathComponent(name))
        }
        #expect(CatalogStockStore.shared.removeRetired(in: dir) == 3)
        let left = try fm.contentsOfDirectory(atPath: dir.path).sorted()
        #expect(left == ["netlabels.json", ArchiveMusicCatalog.shellacAll.key + ".json"].sorted())
        // A second start finds nothing more.
        #expect(CatalogStockStore.shared.removeRetired(in: dir) == 0)
    }

    @Test("no living area is retired, and the start retires", .needsTheSources)
    func noLiveSurfaceIsRetired() throws {
        let live = Set(ArchiveMusicCatalog.all.map(\.key))
        #expect(live.isDisjoint(with: CatalogStockStore.retiredSurfaces))
        let app = SyncContractFenceTests.stripped(try String(
            contentsOf: SourceTree.root.appendingPathComponent("Sources/MaerApp.swift"), encoding: .utf8))
        #expect(app.contains("CatalogStockStore.shared.removeRetired()"))
    }
}
#endif
