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
    /// pipes, minus the closing one where the line has one (a row may leave
    /// it out, and counting it anyway would hide one surplus cell).
    /// Leading and trailing spaces do not count: an indented row is a row.
    nonisolated static func cells(_ line: String) -> Int {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        var count = 0
        var previous: Character = " "
        for ch in trimmed {
            if ch == "|" && previous != "\\" { count += 1 }
            previous = ch
        }
        let closes = trimmed.hasSuffix("|") && !trimmed.hasSuffix("\\|")
        return closes ? count - 1 : count
    }

    /// Rows with more cells than their header, as "line: cells > header".
    /// A table is a header line, its separator, and the pipe lines after.
    ///
    /// Only MORE is a finding, on purpose: the renderer drops the surplus
    /// of an overfull row without a word, while a short row shows all its
    /// content and leaves the missing cells empty. Measured 23.09.2026: 306
    /// of 389 rows are short, the rows from before the fourth column
    /// „Zeugen / Zaun / Auftrag"; none of them loses a word.
    nonisolated static func overfullRows(in text: String) -> [String] {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var header: Int?
        var out: [String] = []
        for (index, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let isSeparator = trimmed.hasPrefix("|") && trimmed.hasSuffix("|")
                && trimmed.allSatisfy { "|-: ".contains($0) }
            if isSeparator, index > 0, lines[index - 1].trimmingCharacters(in: .whitespaces).hasPrefix("|") {
                header = cells(lines[index - 1])
                continue
            }
            guard trimmed.hasPrefix("|") else { header = nil; continue }
            if let header, cells(line) > header { out.append("\(index + 1): \(cells(line)) > \(header)") }
        }
        return out
    }

    @Test("no table row of the inventory has more cells than its header", .needsTheDocs)
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
        // An indented row is a row, and a row without its closing pipe
        // still counts every cell.
        #expect(Self.overfullRows(in: table + "  | a | b | c |\n") == ["4: 3 > 2"], "eingerueckt")
        #expect(Self.overfullRows(in: table + "| a | b | c\n") == ["4: 3 > 2"], "ohne Schluss-Strich")
        #expect(Self.overfullRows(in: table + "| a | b\n").isEmpty, "ohne Schluss-Strich, richtig lang")
        #expect(Self.overfullRows(in: table + "| a |\n").isEmpty, "eine kurze Zeile verliert nichts")
    }
}
#endif
