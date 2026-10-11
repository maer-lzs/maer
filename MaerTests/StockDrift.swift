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

    /// The numeric stocks a test text declares (per name a count, with or
    /// without a reason, or one number named a stock), outside the fixture
    /// texts it carries between triple quotes.
    nonisolated static func numericStocks(in text: String) -> [String] {
        var names: [String] = []
        var inFixture = false
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            // Plain text first: the expressions below run only on the few
            // lines that can declare a stock (all of them over every line of
            // the suite took a minute).
            let fixtureEdge = raw.contains("\"\"\"")
            let candidate = raw.contains("let ") && (raw.contains("[") || raw.contains("tock"))
            guard fixtureEdge || candidate else { continue }
            let line = raw.trimmingCharacters(in: .whitespaces)
            let quotes = fixtureEdge ? line.components(separatedBy: "\"\"\"").count - 1 : 0
            defer { if quotes % 2 == 1 { inFixture.toggle() } }
            guard candidate, !inFixture, !line.hasPrefix("//") else { continue }
            // A count per name is a stock when it is declared on the type;
            // with a reason per entry it is one wherever it is declared. A
            // local `[String: Int]` is a value the case works with.
            if let match = line.firstMatch(of: #/^(?:nonisolated )?(?:private )?static let (\w+): \[String: Int\]/#)
                ?? line.firstMatch(of: #/^(?:nonisolated )?(?:private )?(?:static )?let (\w+): \[String: \(count: Int, reason: String\)\]/#)
                ?? line.firstMatch(of: #/^(?:nonisolated )?(?:private )?static let (\w+) = \["[^"]+": [0-9]/#)
                ?? line.firstMatch(of: #/^(?:nonisolated )?(?:private )?static let (\w*[Ss]tock\w*)(?:: Int)? = [0-9]/#) {
                names.append(String(match.1))
            }
        }
        return names
    }

    /// The stocks of `text` that neither reach `StockDrift` (directly, or as
    /// the argument `stock:` of a check that does) nor are compared for
    /// equality: such a stock locks one way at most.
    nonisolated static func unchecked(in text: String) -> [String] {
        unchecked(numericStocks(in: text), in: text)
    }

    /// The same for stocks already found in `text`.
    nonisolated static func unchecked(_ stocks: [String], in text: String) -> [String] {
        guard !stocks.isEmpty else { return [] }
        let code = SyncContractFenceTests.stripped(text)
        let readsTheDrift = code.contains("StockDrift.findings(") || code.contains("StockDrift.total(")
        return stocks.filter { name in
            let lines = code.split(separator: "\n").map(String.init).filter { $0.contains(name) }
            let byDrift = readsTheDrift && lines.contains { line in
                line.contains("StockDrift.") || line.contains("stock: Self.\(name)") || line.contains("stock: \(name)")
            }
            let byEquality = lines.contains { line in
                line.contains("== Self.\(name)") || line.contains("== \(name)")
                    || line.contains("Self.\(name) ==") || line.contains("Self.\(name).mapValues(\\.count) ==")
            }
            return !(byDrift || byEquality)
        }
    }

    /// Every numeric stock of the suite goes through `StockDrift` or is
    /// compared for equality, so a stock that locks one way only cannot
    /// come back where a search for one spelling of the check did not look.
    @Test("jeder Zahlen-Bestand der Tests geht ueber StockDrift oder wird auf Gleichheit verglichen", .needsTheSources)
    func everyStockLocksBothWays() throws {
        let walker = try #require(FileManager.default.enumerator(
            at: SourceTree.root.appendingPathComponent("MaerTests"), includingPropertiesForKeys: nil))
        var declared = 0
        var oneWay: [String] = []
        for case let file as URL in walker where file.pathExtension == "swift" && file.lastPathComponent != "StockDrift.swift" {
            let text = try String(contentsOf: file, encoding: .utf8)
            let stocks = Self.numericStocks(in: text)
            declared += stocks.count
            oneWay += Self.unchecked(stocks, in: text).map { "\(file.lastPathComponent): \($0)" }
        }
        #expect(declared > 0, "the finder found no stock, it measures nothing")
        #expect(oneWay.isEmpty, "a stock that does not lock both ways: \(oneWay.sorted())")
        // The samples are put together, so the reader of declared stocks in
        // the sources (`StockReasonFenceTests`) does not take them for stocks.
        let head = "nonisolated static " + "let fooStock: [String: Int] = [\"A.swift\": 2]"
        let upward = head + "\nif count > (Self.fooStock[name] ?? 0) { bad() }"
        let drift = head + "\nlet d = StockDrift.findings(counts: c, stock: Self.fooStock)"
        let equal = "static " + "let marks: [String: (count: Int, reason: String)] = [:]\n#expect(found == Self.marks.mapValues(\\.count))"
        let fixture = "let t = \"\"\"\n    static " + "let stock: [String: Int] = [\"X.swift\": 1]\n    \"\"\""
        #expect(Self.unchecked(in: upward) == ["fooStock"], "the fence misses a stock that locks upward only")
        #expect(Self.unchecked(in: drift).isEmpty && Self.unchecked(in: equal).isEmpty, "the fence counts a checked stock")
        #expect(Self.numericStocks(in: fixture).isEmpty, "the fence reads a fixture text as a stock")
    }
}
#endif
