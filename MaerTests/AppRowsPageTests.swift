// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// The rows page: every switchable row says what it draws from or shows,
/// one class carries one name, the second lines stand beside the switch,
/// and the logo diagnosis is no control for the person.
struct AppRowsPageTests {
    @Test("jede schaltbare Reihe hat eine Unterzeile")
    func everySwitchableRowHasASecondLine() {
        let without = AppRows.all.filter { $0.toggleable && (AppRows.subline($0) ?? "").isEmpty }.map(\.key)
        #expect(without.isEmpty, "rows without a second line: \(without)")
    }

    @Test("der Katalog der Hoerbuecher und Hoerspiele heisst am Start und im Reiter gleich")
    func theCatalogCarriesOneName() throws {
        let home = try #require(AppRows.row(key: "home.discoverBooks"))
        let books = try #require(AppRows.row(key: "books.catalog"))
        #expect(home.title.hasSuffix(books.title), "\(home.title) and \(books.title) name one class twice")
    }

    @Test("die Unterzeilen stehen im Label des Schalters, in einem Grau", .needsTheSources)
    func theSecondLinesStandBesideTheSwitch() throws {
        let code = SyncContractFenceTests.stripped(try String(
            contentsOf: SourceTree.root.appendingPathComponent("Sources/Views/RowsSettingsView.swift"), encoding: .utf8))
        // The switch, then its label with the lines, then the modifier on
        // the switch: the lines are inside the switch's label.
        let toggle = try #require(code.range(of: "AppSwitch(isOn: Binding("), "the switch moved")
        let lines = try #require(code.range(of: "lines", range: toggle.upperBound..<code.endIndex))
        let identifier = try #require(code.range(of: ".accessibilityIdentifier(\"row-toggle-"))
        #expect(lines.upperBound <= identifier.lowerBound, "the second lines left the switch's label")
        #expect(!code.contains(".tertiary"), "a second line in the grey that measured 1.7 to 1")
    }

    @Test("die Logo-Diagnose steht nur im Entwicklungsbau", .needsTheSources)
    func theLogoDiagnosisIsDebugOnly() throws {
        let code = try String(contentsOf: SourceTree.root.appendingPathComponent("Sources/Views/Radio/RadioView.swift"), encoding: .utf8)
        #expect(Self.namesOutsideDebug("logoDiagnosisSection", in: code) == 0, "the diagnosis reaches a release build")
        #expect(Self.namesOutsideDebug("x", in: "#if DEBUG\nx\n#endif\nx") == 1)
    }

    /// Lines naming `token` that stand outside an `#if DEBUG` block.
    nonisolated static func namesOutsideDebug(_ token: String, in code: String) -> Int {
        var depth = 0
        var count = 0
        for line in code.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("#if DEBUG") { depth += 1; continue }
            if trimmed.hasPrefix("#endif"), depth > 0 { depth -= 1; continue }
            if depth == 0, !trimmed.hasPrefix("//"), trimmed.contains(token) { count += 1 }
        }
        return count
    }
}
#endif
