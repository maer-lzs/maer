// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// In the settings every row with a symbol stands on one text edge: no row
/// indents itself by a number of its own, and no symbol is wider than the
/// column the list gives it (seen on the device at 375 pt).
struct SettingsEdgeTests {
    static let settingsFiles = ["SettingsView.swift", "PodcastSourceView.swift", "SourceMapCard.swift",
                                "MaerSyncSettingsView.swift", "GPodderSettingsView.swift",
                                "Podcasts/PodcastShowSettingsSheet.swift", "MediaTypeSourcesSection.swift"]

    /// Symbols measured wider than the list's icon column.
    static let wideSymbols = ["photo.on.rectangle"]

    @Test("keine Zeile der Einstellungen rueckt sich um eine eigene Zahl ein, kein Symbol ist breiter als die Spalte", .needsTheSources)
    func everyRowStandsOnOneEdge() throws {
        var indents: [String] = []
        var wide: [String] = []
        for name in Self.settingsFiles {
            let code = SyncContractFenceTests.stripped(try String(
                contentsOf: SourceTree.root.appendingPathComponent("Sources/Views/\(name)"), encoding: .utf8))
            for line in code.split(separator: "\n") {
                if line.range(of: #"\.padding\(\.leading, [0-9]+\)"#, options: .regularExpression) != nil {
                    indents.append("\(name): \(line.trimmingCharacters(in: .whitespaces))")
                }
                for symbol in Self.wideSymbols where line.contains("\"\(symbol)\"") {
                    wide.append("\(name): \(symbol)")
                }
            }
        }
        #expect(indents.isEmpty, "a row indents itself off the text edge: \(indents)")
        #expect(wide.isEmpty, "a symbol wider than the icon column: \(wide)")
    }

    /// At an accessibility size the system lets a wrapped title flow under
    /// the symbol while the separator stays at the title's edge (AX3,
    /// measured); `RowLabelStyle` keeps the title's edge. The settings sheet
    /// sets it for its rows, and the two components whose label a style
    /// from outside does not reach set it on their own.
    @Test("bei Bedienungshilfen-Groessen behalten Titel ihre Kante: das Einstellungsblatt, der Schalter und die Hinweiszeile tragen den Stil", .needsTheSources)
    func titlesKeepTheirEdgeAtAccessibilitySizes() throws {
        func code(_ path: String) throws -> String {
            SyncContractFenceTests.stripped(try String(
                contentsOf: SourceTree.root.appendingPathComponent(path), encoding: .utf8))
        }
        let library = try code("Sources/Views/LibraryView.swift")
        let sheet = try #require(library.range(of: "SettingsView(coordinator:"))
        let afterSheet = String(library[sheet.upperBound...].prefix(400))
        #expect(afterSheet.contains(".labelStyle(RowLabelStyle())"), "the settings sheet does not set the row label")
        let toggle = try #require(ABSPodcastRefreshTests.body(of: "Toggle(isOn: isOn) {", in: try code("Sources/Views/AppSwitch.swift")))
        #expect(toggle.contains(".labelStyle(RowLabelStyle())"), "the switch leaves its label to the system")
        #expect(try code("Sources/Views/HintLine.swift").contains(".labelStyle(RowLabelStyle())"), "the hint line leaves its label to the system")
    }
}
#endif
