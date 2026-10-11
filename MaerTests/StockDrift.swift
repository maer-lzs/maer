// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation

/// The one check of a fence's stock: what the code holds against what the
/// stock allows, in both directions. A count above its entry is growth; a
/// count below it is padding, a free place a new site would take unseen;
/// an entry at zero names nothing. A stock is written to the count in the
/// same commit that changes the count, rising only as a measured number.
/// Fixed caps that are a rule (at most so many of a kind) are no stock and
/// do not come here.
nonisolated enum StockDrift {
    /// Every finding of a stock kept per name; `counts` is what the scan
    /// found, names it found nothing in may be left out.
    static func findings(counts: [String: Int], stock: [String: Int]) -> [String] {
        var out: [String] = []
        for (name, count) in counts.sorted(by: { $0.key < $1.key }) where count > (stock[name] ?? 0) {
            out.append("\(name): \(count) > \(stock[name] ?? 0), grown")
        }
        for (name, allowed) in stock.sorted(by: { $0.key < $1.key }) {
            let count = counts[name] ?? 0
            if allowed <= 0 {
                out.append("\(name): an entry at \(allowed)")
            } else if count < allowed {
                out.append("\(name): \(count) < \(allowed), padding")
            }
        }
        return out
    }

    /// The finding of a stock kept as one total, nil when the count is the stock.
    static func total(_ found: Int, stock: Int) -> String? {
        if found > stock { return "\(found) > \(stock), grown" }
        if found < stock { return "\(found) < \(stock), padding" }
        return nil
    }
}

struct StockDriftTests {
    @Test("ein Bestand sperrt in beide Richtungen: gewachsen, Polster und ein Eintrag auf null reissen, die Zaehlung selbst nicht")
    func aStockLocksBothWays() {
        let stock = ["A.swift": 2, "B.swift": 1]
        #expect(StockDrift.findings(counts: ["A.swift": 2, "B.swift": 1], stock: stock).isEmpty)
        #expect(StockDrift.findings(counts: ["A.swift": 3, "B.swift": 1], stock: stock) == ["A.swift: 3 > 2, grown"])
        #expect(StockDrift.findings(counts: ["A.swift": 1, "B.swift": 1], stock: stock) == ["A.swift: 1 < 2, padding"])
        #expect(StockDrift.findings(counts: ["A.swift": 2], stock: stock) == ["B.swift: 0 < 1, padding"])
        #expect(StockDrift.findings(counts: ["A.swift": 2, "C.swift": 1], stock: ["A.swift": 2]) == ["C.swift: 1 > 0, grown"])
        #expect(StockDrift.findings(counts: [:], stock: ["Z.swift": 0]) == ["Z.swift: an entry at 0"])
        #expect(StockDrift.total(5, stock: 5) == nil)
        #expect(StockDrift.total(6, stock: 5) == "6 > 5, grown")
        #expect(StockDrift.total(4, stock: 5) == "4 < 5, padding")
    }
}
#endif
