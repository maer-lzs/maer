// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// The side column is built once: one capsule, one round button. No other
/// place builds a part of it, and its measure, spacing and material stand in
/// `SideColumnStyle`.
struct SideColumnPartsTests {
    /// The one place that names the column's material besides the two
    /// parts: the playback bar beside the column takes the same glass.
    nonisolated static let materialUsers: Set<String> = ["SideColumnParts.swift", "MiniPlayerBar.swift"]

    /// Lines of code that give a view the column's glass.
    nonisolated static func materialLines(in text: String) -> Int {
        SyncContractFenceTests.stripped(text).components(separatedBy: "SideColumnStyle.tier").count - 1
            + SyncContractFenceTests.stripped(text).components(separatedBy: "tier: .sideColumn").count - 1
    }

    @Test("keine Kapsel und kein runder Knopf der Spalte ausserhalb der zwei Bauteile", .needsTheSources)
    func theColumnIsBuiltOnce() throws {
        var users: Set<String> = []
        for (name, text) in ProjectFileIntegrityTests.sourceTexts(in: ["Sources"]) where name != "AdaptiveGlassBackground.swift" {
            if Self.materialLines(in: text) > 0 { users.insert(name) }
        }
        #expect(users == Self.materialUsers, "the column's glass is put on elsewhere: \(users.subtracting(Self.materialUsers))")
        // The tab bar takes the capsule upright, not a glass of its own.
        let bar = SyncContractFenceTests.stripped(try String(
            contentsOf: SourceTree.root.appendingPathComponent("Sources/Views/MediaTabBar.swift"), encoding: .utf8))
        #expect(bar.contains("SideCapsule {"))
        #expect(bar.contains("private static let pillGap = SideColumnStyle.pillGap"))
        #expect(!bar.contains("CGFloat = 5") && !bar.contains("CGFloat = 4"), "the bar keeps a measure of its own")
        // Rot-Probe of the counter: a view with the column's glass is seen.
        #expect(Self.materialLines(in: ".modifier(AdaptiveGlassBackground(shape: Circle(), tier: .sideColumn))") == 1)
    }
}
#endif
