// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// `UserChoiceCatalog.sourceSwitches` is a list by hand beside the two doors
/// of the sources: the tab switches in the settings and the source switches
/// on the map. An adopted switch that is missing from the list leaves the
/// clients as they were until the next foreground; a list entry no door
/// switches is a claim about nothing. The fence holds both directions.
struct SourceSwitchesFenceTests {
    /// The key NAME behind every `@AppStorage(AppStorageKeys.<name>)` of a
    /// file, with the variable it binds.
    nonisolated static func storedSwitches(in text: String) -> [(key: String, variable: String)] {
        text.matches(of: #/@AppStorage\(AppStorageKeys\.(\w+)\)\s*(?:private\s+)?var\s+(\w+)/#)
            .map { (String($0.output.1), String($0.output.2)) }
    }

    /// The variables a file hands to `tabMasterToggle(…, isOn: $variable)`.
    nonisolated static func tabMasterVariables(in text: String) -> Set<String> {
        Set(text.matches(of: #/tabMasterToggle\([^)]*isOn:\s*\$(\w+)/#).map { String($0.output.1) })
    }

    /// `static let name = "value"` of the key file, so the fence compares the
    /// stored keys and not the Swift names.
    nonisolated static func keyValues(in text: String) -> [String: String] {
        Dictionary(text.matches(of: #/static let (\w+) = "([^"]+)"/#)
            .map { (String($0.output.1), String($0.output.2)) }, uniquingKeysWith: { first, _ in first })
    }

    /// The stored keys the two doors switch: every stored switch of the map,
    /// and in the settings the ones behind a tab master toggle.
    nonisolated static func doorKeys(sourceMap: String, settings: String, keys: String) -> Set<String> {
        let values = keyValues(in: keys)
        let tabVariables = tabMasterVariables(in: settings)
        let names = storedSwitches(in: sourceMap).map(\.key)
            + storedSwitches(in: settings).filter { tabVariables.contains($0.variable) }.map(\.key)
        return Set(names.compactMap { values[$0] })
    }

    @Test("die Liste der Quellen-Schalter ist genau, was die zwei Tueren schalten", .needsTheSources)
    func theListIsWhatTheDoorsSwitch() throws {
        func read(_ path: String) throws -> String {
            try String(contentsOf: SourceTree.root.appendingPathComponent(path), encoding: .utf8)
        }
        let doors = Self.doorKeys(sourceMap: try read("Sources/Views/SourceMapCard.swift"),
                                  settings: try read("Sources/Views/SettingsView.swift"),
                                  keys: try read("Sources/Models/AppStorageKeys.swift"))
        #expect(doors.count >= 10, "the fence found the doors' switches: \(doors.sorted())")
        #expect(doors.subtracting(UserChoiceCatalog.sourceSwitches).isEmpty,
                "a door switches a source the list does not know: \(doors.subtracting(UserChoiceCatalog.sourceSwitches).sorted())")
        #expect(UserChoiceCatalog.sourceSwitches.subtracting(doors).isEmpty,
                "the list names a switch no door switches: \(UserChoiceCatalog.sourceSwitches.subtracting(doors).sorted())")
        // The reader sees a tab toggle and leaves an unrelated stored value out.
        let settings = """
        @AppStorage(AppStorageKeys.a) private var aTab = true
        @AppStorage(AppStorageKeys.b) private var other = 1
        tabMasterToggle("A", isOn: $aTab)
        """
        #expect(Self.doorKeys(sourceMap: "", settings: settings,
                              keys: "static let a = \"aKey\"\nstatic let b = \"bKey\"") == ["aKey"])
    }
}
#endif
