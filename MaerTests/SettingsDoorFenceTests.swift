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
/// else asks the door. The stock below is the count, both ways
/// (`StockDrift`); it is empty since the move is complete.
struct SettingsDoorFenceTests {
    /// Die drei Heimaten des Schluessel-Topfs, jede mit ihrem Grund IM
    /// Eintrag. `AppStorageKeys` steht als PRAEFIX, weil die Tuer auf
    /// mehrere Dateien verteilt ist.
    nonisolated static let homes: [(match: String, reason: String)] = [
        ("/Sources/Storage/", "die Zeilen-Schicht, die ihren eigenen Bestand haelt"),
        ("/Ablage.swift", "die Datei-Naht, die neben den Zeilen steht"),
        ("/ListeningStore.swift", "der Hoerbestand, der eigene Schluessel fuehrt"),
        ("AppStorageKeys", "die Tuer selbst, ueber ihre Dateien verteilt"),
    ]

    nonisolated static func isAHome(_ path: String) -> Bool {
        homes.contains { entry in
            entry.match.hasPrefix("/")
                ? path.contains(entry.match)
                : URL(fileURLWithPath: path).lastPathComponent.hasPrefix(entry.match)
        }
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
        var counts: [String: Int] = [:]
        for file in ProjectFileIntegrityTests.sourceFiles() where !Self.isAHome(file.path) {
            let count = Self.sites(in: try String(contentsOf: file, encoding: .utf8))
            guard count > 0 else { continue }
            counts[file.lastPathComponent, default: 0] += count
        }
        let drift = StockDrift.findings(counts: counts, stock: Self.stock)
        #expect(drift.isEmpty, "these files reach past the door, or a stock above the count: \(drift)")
        // Red probes on the checker.
        #expect(Self.sites(in: "let x = UserDefaults.standard.bool(forKey: k)") == 1)
        #expect(Self.sites(in: "let x = AppStorageKeys.bool(k)") == 0)
        #expect(Self.isAHome("/x/Sources/Models/AppStorageKeys+Door.swift"))
        #expect(!Self.isAHome("/x/Sources/Views/SettingsView.swift"))
    }
}
#endif
