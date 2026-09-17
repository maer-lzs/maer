// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// The inventory's tables render as the renderer counts them: every
/// unescaped pipe is a cell border, inside backticks too, and a row with
/// more cells than its header loses the surplus without a word (GFM drops
/// it). Measured 17.09.2026: 69 rows carried a fourth cell the rendered
/// page never showed, four of them from an unmasked `||`.
struct ComponentsTableFenceTests {
    /// The cell count of a table line as the renderer sees it: unescaped
    /// pipes, minus the closing one.
    nonisolated static func cells(_ line: String) -> Int {
        var count = 0
        var previous: Character = " "
        for ch in line {
            if ch == "|" && previous != "\\" { count += 1 }
            previous = ch
        }
        return count - 1
    }

    /// Rows with more cells than their header, as "line: cells > header".
    /// A table is a header line, its separator, and the pipe lines after.
    nonisolated static func overfullRows(in text: String) -> [String] {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var header: Int?
        var out: [String] = []
        for (index, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let isSeparator = trimmed.hasPrefix("|") && trimmed.hasSuffix("|")
                && trimmed.allSatisfy { "|-: ".contains($0) }
            if isSeparator, index > 0, lines[index - 1].hasPrefix("|") {
                header = cells(lines[index - 1])
                continue
            }
            guard line.hasPrefix("|") else { header = nil; continue }
            if let header, cells(line) > header { out.append("\(index + 1): \(cells(line)) > \(header)") }
        }
        return out
    }

    @Test("keine Tabellenzeile des Inventars hat mehr Zellen als ihr Kopf")
    func noRowHasMoreCellsThanItsHeader() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let text = try String(contentsOf: root.appendingPathComponent("docs/components.md"), encoding: .utf8)
        let overfull = Self.overfullRows(in: text)
        #expect(overfull.isEmpty, "rows whose surplus cells the renderer drops: \(overfull)")
        // The checker sees the surplus, the escape and the code span.
        let table = "| A | B |\n|---|---|\n| a | b |\n"
        #expect(Self.overfullRows(in: table).isEmpty)
        #expect(Self.overfullRows(in: table + "| a | b | c |\n") == ["4: 3 > 2"])
        #expect(Self.overfullRows(in: table + "| a | `x || y` |\n") == ["4: 4 > 2"])
        #expect(Self.overfullRows(in: table + "| a | `x \\|\\| y` |\n").isEmpty)
        #expect(Self.overfullRows(in: table + "\nprose | with | pipes\n").isEmpty, "only table lines count")
    }
}
#endif
