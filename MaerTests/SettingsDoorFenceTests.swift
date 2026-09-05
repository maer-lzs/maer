// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// `UserDefaults.standard` has three homes: the settings door
/// (`AppStorageKeys` and its extensions), the listening stock
/// (`ListeningStore`) and the storage layer (Ablage, Storage). Everything
/// else asks the door. The stock below is the inventory of the day the
/// fence was built; a file may only lose sites, never gain them, and the
/// list shrinks to nothing as the move proceeds.
struct SettingsDoorFenceTests {
    nonisolated static func isAHome(_ path: String) -> Bool {
        path.contains("/Sources/Storage/")
            || path.hasSuffix("/Ablage.swift")
            || path.hasSuffix("/ListeningStore.swift")
            || URL(fileURLWithPath: path).lastPathComponent.hasPrefix("AppStorageKeys")
    }

    nonisolated static func sites(in text: String) -> Int {
        text.components(separatedBy: "UserDefaults.standard").count - 1
    }

    /// The remaining sites outside the homes, by file. Empty: the move is
    /// complete (154 sites in 43 files on the day the fence was built). A
    /// new site anywhere is red.
    nonisolated static let stock: [String: Int] = [:]

    @Test("UserDefaults.standard nur in der Tuer, dem Bestand und der Ablage; der Rest schrumpft")
    func onlyTheDoorsTouchTheStore() throws {
        var grown: [String] = []
        var remaining = 0
        for file in ProjectFileIntegrityTests.sourceFiles() where !Self.isAHome(file.path) {
            let count = Self.sites(in: try String(contentsOf: file, encoding: .utf8))
            guard count > 0 else { continue }
            remaining += count
            let allowed = Self.stock[file.lastPathComponent] ?? 0
            if count > allowed { grown.append("\(file.lastPathComponent): \(count) > \(allowed)") }
        }
        #expect(grown.isEmpty, "these files reach past the door (or grew): \(grown)")
        #expect(remaining <= Self.stock.values.reduce(0, +), "the stock outside the door must not grow")
        // Red probes on the checker.
        #expect(Self.sites(in: "let x = UserDefaults.standard.bool(forKey: k)") == 1)
        #expect(Self.sites(in: "let x = AppStorageKeys.bool(k)") == 0)
        #expect(Self.isAHome("/x/Sources/Models/AppStorageKeys+Door.swift"))
        #expect(!Self.isAHome("/x/Sources/Views/SettingsView.swift"))
    }
}
#endif
