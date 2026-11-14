// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
@testable import Maer

/// The listening totals read their two tables on their own: a table that
/// cannot be read leaves the other one's rows standing, as the stock the
/// store starts with and as what a write may remove.
struct ListeningStatsStartTests {
    private typealias Load = ListeningStatsStore.StatsTable.Load

    @Test("if the statistics read only one table, they start with it and hold it as read")
    func aTableThatWasReadStands() {
        let days = Load(rows: ["2026-10-04": 600], skipped: 0)
        let (stock, base) = ListeningStatsStore.startBase(days: days, items: nil)
        #expect(stock?.secondsPerDay == ["2026-10-04": 600], "the store starts without the day it read")
        #expect(base.plan == .removeSeen, "a table that could not be read leaves the rows unknown with what was read")
        #expect(base.map(\.secondsPerDay).removable == ["2026-10-04": 600])
        #expect(base.map(\.secondsPerItem).removable == [:], "nothing of the unread table may be removed")
        // The first write after it keeps today's value and adds to it.
        let after = ["2026-10-04": 660]
        #expect(base.map(\.secondsPerDay).previous(for: after).isEmpty, "the read day is no removal")
        #expect(!base.map(\.secondsPerItem).refuses(["it": 60], .refused))
    }

    @Test("both tables read: known, fresh or, with skipped rows, unknown as before")
    func bothTablesRead() {
        let days = Load(rows: ["d": 1], skipped: 0)
        let items = Load(rows: ["i": 2], skipped: 0)
        #expect(ListeningStatsStore.startBase(days: days, items: items).base.knownValue
                == ListeningStatsData(secondsPerDay: ["d": 1], secondsPerItem: ["i": 2]))
        let empty = Load(rows: [:], skipped: 0)
        let fresh = ListeningStatsStore.startBase(days: empty, items: empty)
        #expect(fresh.stock == nil)
        if case .fresh = fresh.base {} else { Issue.record("nothing read, nothing skipped: fresh") }
        let skipped = ListeningStatsStore.startBase(days: days, items: Load(rows: [:], skipped: 1))
        #expect(skipped.base.plan == .removeSeen && skipped.stock?.secondsPerDay == ["d": 1])
        let none = ListeningStatsStore.startBase(days: nil, items: nil)
        #expect(none.stock == nil && none.base.plan == .upsertOnly, "nothing could be read: nothing to remove")
    }
}
#endif
