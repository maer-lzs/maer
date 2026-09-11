// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// The keepers' one door for the app's two ends: every keeper registers
/// itself, `RowKeepers.awaitAll` waits for every living chain, and what
/// died is forgotten.
@MainActor
struct RowKeeperTests {
    private func database() throws -> (MaerDatabase, URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("keeper-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return (MaerDatabase(path: directory.appendingPathComponent("maer.sqlite").path), directory)
    }

    @Test("awaitAll wartet jede lebende Kette ab, ein Keeper meldet sich beim Entstehen an, ein toter faellt raus")
    func awaitAllSettlesEveryLivingKeeper() async throws {
        let (database, directory) = try database()
        defer { try? FileManager.default.removeItem(at: directory) }
        let before = RowKeepers.count
        var keeper: RowKeeper<[String]>? = RowKeeper(database: database, table: .playQueue, label: "PROBE")
        #expect(RowKeepers.count == before + 1, "a keeper registers itself on creation")
        keeper?.write(["k": ["a"]])
        keeper?.write(["k": ["a", "b"]])
        let waited = await RowKeepers.awaitAll()
        #expect(waited >= 1)
        let reader = try #require(try database.readerNow())
        #expect(try KeyedRowStore<[String]>.loadNow(table: .playQueue, reader: reader).rows["k"] == ["a", "b"],
                "after awaitAll the last write has landed")
        keeper = nil
        #expect(RowKeepers.count == before, "a dead keeper is forgotten")
    }
}
#endif
