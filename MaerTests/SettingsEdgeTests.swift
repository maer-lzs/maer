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
    /// The settings files the name rule does not find (every file under
    /// `Sources/Views` with "Settings" or "SourceView" in its name counts by
    /// itself), each with what it is in the settings.
    static let alsoSettings: [String: String] = [
        "SourceMapCard.swift": "the map of areas and its pages",
        "MediaTypeSourcesSection.swift": "the sources of a media type",
        "SourceLibraryAssignmentSection.swift": "which library a server's titles land in",
        "ServerGuidesSection.swift": "the guides to the servers",
        "SyncHistoryView.swift": "the sync history",
        "NextStepsView.swift": "the next steps, also reached from the settings",
    ]

    /// Lines that move a row off the text edge by a value of their own but
    /// are no row indent, each with its reason. An entry whose line is gone
    /// turns the fence red, so the list only holds what still stands.
    static let notRowIndents: [String: String] = [
        "SettingsView.swift: .padding(.horizontal, 12)":
            "the inner padding of a tab choice capsule, measured to fit five text pills at 430 pt; no row",
        "RowsSettingsView.swift: .padding(.leading, row.group == nil ? 0 : 16)":
            "the switches of a group of shares stand under the group's title; whether they indent is a visible choice, put to the review",
    ]

    /// Symbols measured wider than the list's icon column, each with its
    /// reason. None is in use today; an entry that no file uses would claim
    /// something about nothing, so the fence turns red on it.
    static let wideSymbols: [String: String] = [:]

    /// Every settings file, relative to `Sources/Views`.
    static func settingsFiles() throws -> [String] {
        let views = SourceTree.root.appendingPathComponent("Sources/Views")
        let walker = try #require(FileManager.default.enumerator(at: views, includingPropertiesForKeys: nil))
        var found: [String] = []
        for case let url as URL in walker where url.pathExtension == "swift" {
            let name = url.lastPathComponent
            guard name.contains("Settings") || name.contains("SourceView") || alsoSettings[name] != nil else { continue }
            found.append(String(SourceTree.relativePath(of: url).dropFirst("Sources/Views/".count)))
        }
        return found.sorted()
    }

    /// A row's own indent: a leading or horizontal padding or an inset, by
    /// any value, not only a written number.
    nonisolated static func ownIndent(_ line: Substring) -> Bool {
        line.range(of: #"\.padding\(\s*\.(leading|horizontal)\s*,|EdgeInsets\("#, options: .regularExpression) != nil
    }

    @Test("keine Zeile der Einstellungen rueckt sich um eine eigene Zahl ein, kein Symbol ist breiter als die Spalte", .needsTheSources)
    func everyRowStandsOnOneEdge() throws {
        let files = try Self.settingsFiles()
        #expect(files.contains("RowsSettingsView.swift") && files.contains("SourcesSettingsView.swift")
                && files.contains("SettingsView.swift"), "the fence does not find the settings: \(files)")
        let names = Set(files.map { ($0 as NSString).lastPathComponent })
        #expect(Set(Self.alsoSettings.keys).subtracting(names).isEmpty,
                "a named settings file is gone: \(Set(Self.alsoSettings.keys).subtracting(names).sorted())")
        var indents: [String] = []
        var wide: [String] = []
        var used: Set<String> = []
        for name in files {
            let code = SyncContractFenceTests.stripped(try String(
                contentsOf: SourceTree.root.appendingPathComponent("Sources/Views/\(name)"), encoding: .utf8))
            for line in code.split(separator: "\n") {
                let entry = "\((name as NSString).lastPathComponent): \(line.trimmingCharacters(in: .whitespaces))"
                if Self.ownIndent(line) {
                    if Self.notRowIndents[entry] != nil { used.insert(entry) } else { indents.append(entry) }
                }
                for symbol in Self.wideSymbols.keys where line.contains("\"\(symbol)\"") {
                    wide.append("\(name): \(symbol)")
                }
            }
        }
        #expect(indents.isEmpty, "a row indents itself off the text edge: \(indents)")
        #expect(Set(Self.notRowIndents.keys).subtracting(used).isEmpty,
                "an exception whose line is gone: \(Set(Self.notRowIndents.keys).subtracting(used).sorted())")
        #expect(wide.isEmpty, "a symbol wider than the icon column: \(wide)")
        let sources = ProjectFileIntegrityTests.sourceTexts()
        let unused = Self.wideSymbols.keys.filter { symbol in !sources.contains { $0.text.contains("\"\(symbol)\"") } }
        #expect(unused.isEmpty, "a wide symbol no file uses: \(unused.sorted())")
        // Calibration: a computed indent and an inset count, a vertical one does not.
        #expect(Self.ownIndent(".padding(.leading, row.group == nil ? 0 : 16)"))
        #expect(Self.ownIndent(".padding(.horizontal, inset)"))
        #expect(Self.ownIndent(".padding(EdgeInsets(top: 0, leading: 8, bottom: 0, trailing: 0))"))
        #expect(!Self.ownIndent(".padding(.vertical, 4)"))
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
