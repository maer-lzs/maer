// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// The stand table keeps the defaults shape intact, imports the stock in
/// one transaction, and never shrinks or overwrites a newer moment.
struct StandStoreTests {
    private func store() async throws -> StandStore {
        try await StandStore(connection: try SQLiteConnection(path: ":memory:"))
    }

    @Test("The defaults shape goes in and comes out the same: two, three and four slots")
    func shapeRoundTrip() async throws {
        let store = try await store()
        try await store.upsert(Stand(itemId: "rss:a", entry: [600, 1_700_000_000_000, 3600])!)
        try await store.upsert(Stand(itemId: "abs:b", entry: [12.5, 1_700_000_000_500])!)
        // Slot 3 is the started form; a form without a duration carries a 0
        // in slot 2, exactly as `ProgressMark.entry` builds it.
        try await store.upsert(Stand(itemId: "abs:c", entry: [30, 1_700_000_000_600, 0, 1])!)
        try await store.upsert(Stand(itemId: "abs:d", entry: [40, 1_700_000_000_700, 900, 2])!)
        #expect(try await store.stand(for: "rss:a")?.entry == [600, 1_700_000_000_000, 3600])
        #expect(try await store.stand(for: "abs:b")?.entry == [12.5, 1_700_000_000_500])
        #expect(try await store.stand(for: "abs:c")?.entry == [30, 1_700_000_000_600, 0, 1])
        #expect(try await store.stand(for: "abs:d")?.entry == [40, 1_700_000_000_700, 900, 2])
        #expect(ProgressMark.markedForm([40, 1_700_000_000_700, 900, 2]) == .work,
                "the form the row carries is the one the entry rules read")
        #expect(Stand(itemId: "x", entry: [1]) == nil, "an entry without a moment is no stand")
        try await store.upsert(Stand(itemId: "rss:a", entry: [900, 1_700_000_001_000, 3600])!)
        #expect(try await store.stand(for: "rss:a")?.position == 900)
        try await store.remove(itemId: "rss:a")
        #expect(try await store.stand(for: "rss:a") == nil)
    }

    /// The import is the normal case (Rule 9): many entries, one stamp, no
    /// fresh action, empty delta on the second run, and it never shrinks.
    @Test("Import from the old stock: everything once, second run empty, never a shrink, never over a newer moment")
    func importIsIdempotentAndNeverShrinks() async throws {
        let store = try await store()
        var stock: [String: [Double]] = [:]
        for i in 0..<500 { stock["rss:seed:\(i)"] = [Double(i), 1_700_000_000_000, 3600] }
        stock["broken"] = [5]                      // no moment: skipped
        #expect(try await store.importEntries(stock) == 500)
        #expect(try await store.count() == 500)
        // Second run: nothing changes.
        #expect(try await store.importEntries(stock) == 0)
        #expect(try await store.count() == 500)
        // A newer row in the table survives an older import of the same title.
        try await store.upsert(Stand(itemId: "rss:seed:1", entry: [999, 1_700_000_009_000])!)
        #expect(try await store.importEntries(stock) == 0)
        #expect(try await store.stand(for: "rss:seed:1")?.position == 999)
        // An empty import over a filled table is a no-op.
        #expect(try await store.importEntries([:]) == 0)
        #expect(try await store.count() == 500)
        // The whole table reads back.
        #expect(try await store.all().count == 500)
    }
}
#endif
