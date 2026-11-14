// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// The item dimension of the listening statistics. The point of the whole
/// design is that there is only ONE count: the day pot is the truth for
/// "listened time", the item pot is the same seconds seen from a different
/// side. Two pots that can drift apart would be the class this project keeps
/// closing. So the invariant gets a test, not a comment.
struct ListeningStatsDimensionTests {

    /// The pure part of the invariant, independent of the store: whatever a
    /// sequence of ticks did, the item sums can never exceed the day sums.
    private func check(_ data: ListeningStatsData) -> Bool {
        data.secondsPerItem.values.reduce(0, +) <= data.secondsPerDay.values.reduce(0, +)
    }

    @Test("the sum per item never exceeds the day sum")
    func itemSumNeverExceedsDaySum() {
        var data = ListeningStatsData()
        // Two titles and a tick without a known id. That one lands ONLY in the
        // day pot, and exactly for that reason the inequality is not an equality.
        data.secondsPerDay["2026-08-19"] = 100
        data.secondsPerItem["radio:rb:a"] = 60
        data.secondsPerItem["rss:x:1"] = 30
        #expect(check(data), "70 von 100 Sekunden sind zugeordnet — erlaubt")

        data.secondsPerItem["radio:rb:b"] = 20
        #expect(!check(data), "110 zugeordnete Sekunden bei 100 gehoerten waeren zwei Wahrheiten")
    }

    @Test("a tick counts in BOTH pots, not twice in one")
    func oneTickCountsOnceInEach() {
        var data = ListeningStatsData()
        for _ in 0..<5 {
            data.secondsPerDay["2026-08-19", default: 0] += 1
            data.secondsPerItem["radio:rb:a", default: 0] += 1
        }
        #expect(data.secondsPerDay["2026-08-19"] == 5)
        #expect(data.secondsPerItem["radio:rb:a"] == 5)
        #expect(check(data))
    }

    @Test("a tick without an id falls only into the day pot")
    func tickWithoutIdOnlyCountsTheDay() {
        var data = ListeningStatsData()
        data.secondsPerDay["2026-08-19"] = 10
        // No item entry: a title whose detail is not there yet must not
        // swallow the listened time. The day sum is the
        // truth, the attribution is the optional extra.
        #expect(data.secondsPerItem.isEmpty)
        #expect(check(data))
    }

    @Test("Stock without an item pot still reads, no migration jump")
    func legacyDataStillDecodes() throws {
        // Exactly the form that is on disk today.
        let legacy = #"{"secondsPerDay":{"2026-08-18":3600,"2026-08-19":120}}"#
        let decoded = try JSONDecoder().decode(ListeningStatsData.self,
                                               from: Data(legacy.utf8))
        #expect(decoded.secondsPerDay["2026-08-18"] == 3600)
        #expect(decoded.secondsPerItem.isEmpty, "die neue Dimension startet leer, nicht fehlend")
        #expect(check(decoded))
    }

    /// The FUNCTION the stats page calls, not a rebuild of its sort: the
    /// cap, the predicate and the stable tie all live in `topItems`, and a
    /// copy of the sort in the test held while the function drifted.
    @Test("Ranking by TIME, ties stable, cap and predicate on the function")
    @MainActor func rankingIsByTime() throws {
        // A database of its own: the default is the app's shared one, where
        // other suites leave items (measured: "loadfail-…" from FailedLoadTests).
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("stats-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let stats = ListeningStatsStore(carrier: KeyValueStatsCarrier(store: InMemoryCloudStore()),
                                        database: MaerDatabase(path: directory.appendingPathComponent("maer.sqlite").path),
                                        history: ListeningStatsSyncTests.RecordingHistory())
        for (id, seconds) in [("radio:rb:a", 3600), ("radio:rb:b", 7200), ("rss:x:1", 1800), ("radio:rb:c", 3600)] {
            stats.addSeconds(seconds, itemId: id)
        }
        let radio = stats.topItems(limit: 10, matching: { $0.hasPrefix("radio:") })
        #expect(radio.map(\.id) == ["radio:rb:b", "radio:rb:a", "radio:rb:c"],
                "zwei Stunden schlagen eine, und der Gleichstand bleibt stabil sortiert")
        #expect(radio.map(\.seconds) == [7200, 3600, 3600])
        #expect(stats.topItems(limit: 2, matching: { $0.hasPrefix("radio:") }).map(\.id) == ["radio:rb:b", "radio:rb:a"],
                "die Kappung nimmt die obersten")
        #expect(stats.topItems(limit: 10).map(\.id) == ["radio:rb:b", "radio:rb:a", "radio:rb:c", "rss:x:1"],
                "ohne Praedikat zaehlt alles")
        #expect(check(stats.data))
    }

    /// A statistics store built in a test without a database of its own
    /// reads the app's shared rows, where other suites leave items; per file,
    /// with the reason it may.
    static let sharedRowsStock: [String: (count: Int, reason: String)] = [
        "AccessFollowersTests.swift": (1, "reads a difference before and after, never the whole content"),
        "StatsLocalPotTests.swift": (1, "its own run's ids only, whatever else the rows hold"),
    ]

    @Test("a statistics store in a test reads its own rows; whoever reads the shared ones is counted per file", .needsTheSources)
    func testStatsReadRowsOfTheirOwn() {
        var counts: [String: Int] = [:]
        let opener = "ListeningStatsStore" + "("
        for (name, text) in ProjectFileIntegrityTests.sourceTexts(in: ["MaerTests"]) {
            let calls = SyncContractFenceTests.stripped(text).components(separatedBy: opener).dropFirst()
            // The arguments of one call: up to the first line that closes it.
            let shared = calls.filter { call in
                let end = call.range(of: ")\n")?.lowerBound ?? call.endIndex
                let args = call[..<end]
                return !args.contains("database:") || args.contains("database: .shared")
            }.count
            if shared > 0 { counts[name] = shared }
        }
        let drift = StockDrift.findings(counts: counts, stock: Self.sharedRowsStock.mapValues(\.count))
        #expect(drift.isEmpty, "a test reads the shared statistics rows unseen: \(drift)")
    }
}
#endif
