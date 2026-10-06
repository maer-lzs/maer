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
}
#endif
