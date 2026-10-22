// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// A cell of the full row page is as wide as its column: on a 393 pt phone
/// two columns of 172.5 pt instead of two 150 pt cells with room beside
/// them.
struct GridColumnsTests {
    @Test("eine Zelle ist so breit wie ihre Spalte, so viele Spalten wie passen")
    func aCellFillsItsColumn() {
        let phone = GridColumns.layout(available: 393 - 32, minimum: 150, spacing: 16)
        #expect(phone == .init(count: 2, width: 172), "two columns on a 393 pt phone, each filled: \(phone)")
        let filled = Double(phone.count) * phone.width + 16 * Double(phone.count - 1)
        #expect(filled <= 361 && filled > 361 - Double(phone.count), "the columns take the width, at most a point lost per column")
        let pad = GridColumns.layout(available: 1024 - 32, minimum: 150, spacing: 16)
        #expect(pad.count == 6 && pad.width >= 150, "a wide page takes as many columns as fit: \(pad)")
    }

    @Test("unter einer Spalte und vor der Messung eine Spalte in der Mindestbreite")
    func belowOneColumnOneColumn() {
        #expect(GridColumns.layout(available: 0, minimum: 150, spacing: 16) == .init(count: 1, width: 150))
        #expect(GridColumns.layout(available: 120, minimum: 150, spacing: 16) == .init(count: 1, width: 150))
        #expect(GridColumns.layout(available: 150, minimum: 150, spacing: 16) == .init(count: 1, width: 150))
        #expect(GridColumns.layout(available: 315, minimum: 150, spacing: 16) == .init(count: 1, width: 315),
                "one point short of two columns: one column, as wide as the page")
        #expect(GridColumns.layout(available: 316, minimum: 150, spacing: 16) == .init(count: 2, width: 150))
    }

    /// The grid gives the column; a tile that draws itself at a fixed
    /// width inside it stands in the column with room on both sides.
    @Test("die Vollseite gibt jeder Zelle die Spaltenbreite, keine Zelle zeichnet fest 150", .needsTheSources)
    func everyCellOfThePageTakesTheColumn() throws {
        let code = SyncContractFenceTests.stripped(try String(
            contentsOf: SourceTree.root.appendingPathComponent("Sources/Views/MixedMediaPage.swift"), encoding: .utf8))
        let tile = try #require(code.components(separatedBy: "struct HomeRecentlyAddedTile").dropFirst().first?
            .components(separatedBy: "\nstruct ").first)
        #expect(!tile.contains("width: 150,") && !tile.contains("width: 150)"), "the tile draws at a fixed width")
        // The last case is the page's grid; the first names the row.
        let added = try #require(code.components(separatedBy: "case .recentlyAdded:").dropFirst().last?
            .components(separatedBy: ".frame(").first)
        #expect(added.contains("HomeRecentlyAddedTile(") && added.contains("width: cardWidth"),
                "the page hands the tile its column's width")
    }
}
#endif
