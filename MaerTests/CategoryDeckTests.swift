// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
import SwiftUI
@testable import Maer

/// The music library entries are ONE deck of tiles on both hosts: the
/// search page and the music tab render `CategoryDeckGrid`, the tab has no
/// row list of its own any more, and the same six entries stand on both.
struct CategoryDeckTests {
    private func sourceText(_ relative: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(relative), encoding: .utf8)
    }

    @Test("Suchseite und Musik-Tab rendern dieselbe Kachel-Liste mit denselben Eintraegen")
    func bothHostsRenderTheOneDeck() throws {
        let search = try sourceText("Sources/Views/SearchScreen.swift")
        let music = try sourceText("Sources/Views/Music/MusicView.swift")
        #expect(search.contains("CategoryDeckGrid(entries:"))
        #expect(music.contains("CategoryDeckGrid(entries:"))
        #expect(!music.contains("browseRow("), "the tab grew a row list of its own again")
        // The search side names its entries no longer in the view but in the
        // rule, so the comparison asks the RULE for its titles instead of
        // grepping the file. The tab still writes them out.
        let searchTitles = Set(SearchDeckTiles.tiles(scope: .music, counts: SearchDeckCounts()).map(\.title))
        // SECHS auf beiden Flaechen: steht „Geladen“ nur auf dem Tab, prueft
        // der Zaun fuenf und behauptet sechs.
        #expect(searchTitles.count == 6, "das Such-Deck traegt nicht sechs Eintraege")
        for title in ["Artists", "Albums", "Songs", "Playlists", "Genres", "Downloaded"] {
            #expect(searchTitles.contains(String(localized: String.LocalizationValue(title))),
                    "entry \(title) missing on the search deck")
            #expect(music.contains("\"\(title)\""), "entry \(title) missing on the music tab")
        }
    }

    /// The radio genres were a hand-built copy of the tile. They render the
    /// one deck now and keep their journey handles.
    @Test("Die Radio-Genres rendern dasselbe Kachel-Raster, kein eigenes")
    func theRadioGenresRenderTheOneDeck() throws {
        let radio = try sourceText("Sources/Views/Radio/RadioView.swift")
        #expect(radio.contains("CategoryDeckGrid(entries: RadioCatalog.genres"), "the radio genres left the deck")
        #expect(!radio.contains("LazyVGrid"), "the radio tab grew a tile grid of its own again")
        #expect(radio.contains("accessibilityId: \"radio-genre-\\(genre.tag)\""), "the journey handle of a genre tile changed")
    }

    /// At AX3 on a 393 pt phone two columns cut even a short title
    /// ("Nac…", "Mu…", measured in the picture). Every grid of category
    /// tiles takes its columns from the one rule.
    @Test("Kachel-Raster: zwei Spalten, in den Bedienhilfe-Groessen eine, und jedes Raster fragt dieselbe Regel")
    @MainActor
    func everyTileGridTakesTheOneColumnRule() throws {
        #expect(CategoryDeckGrid.columns(for: .large).count == 2)
        #expect(CategoryDeckGrid.columns(for: .xxxLarge).count == 2)
        #expect(CategoryDeckGrid.columns(for: .accessibility1).count == 1)
        #expect(CategoryDeckGrid.columns(for: .accessibility3).count == 1)
        // Every file that builds a tile, found rather than named: a fourth
        // file with a grid of its own would stand outside a named list.
        let tileFiles = try ProjectFileIntegrityTests.sourceFiles()
            .filter { try String(contentsOf: $0, encoding: .utf8).contains("CategoryTile(") }
            .map { $0.path.components(separatedBy: "/Sources/").last.map { "Sources/" + $0 } ?? $0.path }
            .sorted()
        #expect(tileFiles == ["Sources/Views/CategoryTile.swift", "Sources/Views/Music/MusicLibraryPages.swift",
                              "Sources/Views/SearchScreen.swift"], "a file with tiles the fence did not know: \(tileFiles)")
        for path in tileFiles {
            let text = try sourceText(path)
            let grids = text.components(separatedBy: "LazyVGrid(columns:").count - 1
            let ruled = text.components(separatedBy: "columns(for: typeSize)").count - 1
            #expect(grids >= 1 && grids == ruled, "\(path): \(grids) tile grids, \(ruled) ask the rule")
        }
    }

    /// Die Kennungen, die eine Journey wörtlich nennt, entstehen ZUSAMMEN-
    /// GESETZT: das Raster stellt `deck-tier-` vor die Kennung der Kachel.
    /// Eine Textsuche in den Quellen findet sie deshalb nicht, und ein
    /// Prüfer, der Zeichenketten zählt, hält sie für tot. Sie sind es
    /// nicht, und dieser Fall hält beide Hälften fest, damit die Zusage
    /// auch dann steht, wenn keine Journey läuft.
    @Test("Die zusammengesetzten Kachel-Kennungen entstehen wirklich")
    func theComposedTileIdentifiersExist() throws {
        // Erste Haelfte, am Verhalten: die Kachel traegt die Kennung, aus
        // der die Journey ihre baut.
        // Der Zeuge haengt an einer Kachel, die es noch gibt: die
        // freie Klassik-Kachel ist auf beiden Flaechen gefallen, die Zusage
        // ueber die zusammengesetzte Kennung gilt unveraendert weiter.
        let ids = Set(SearchDeckTiles.tiles(scope: .music, counts: SearchDeckCounts()).map(\.id))
        #expect(ids.contains("music-downloaded"))
        #expect(!ids.contains("music-free-classical"), "die freie Kachel ist zurueck")
        // Zweite Haelfte, am Quelltext: das Raster setzt genau dieses
        // Praefix davor, wenn die Kachel keine eigene Kennung mitbringt.
        let grid = try sourceText("Sources/Views/CategoryTile.swift")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
        #expect(grid.contains("entry.accessibilityId ?? \"deck-tier-\\(entry.id)\""))
    }

    @Test("Eine Zahl steht nur, wo sie bekannt ist")
    func countOnlyWhereKnown() {
        let entry = CategoryDeckEntry(id: "songs", title: "Songs", systemImage: "music.note", count: nil) {}
        #expect(entry.count == nil)
        #expect(entry.accessibilityId == nil, "the grid derives the handle from the id")
    }

    /// The search tile carries the short title; VoiceOver says the full one.
    @Test("die Such-Kachel heisst kurz Hoerbuecher und nennt VoiceOver den vollen Titel")
    func theSearchTileSaysTheFullTitle() throws {
        let search = try sourceText("Sources/Views/SearchScreen.swift")
        #expect(search.contains("CategoryTile(title: String(localized: \"Audiobooks\")"))
        #expect(search.contains(".accessibilityLabel(Text(\"Audiobooks and Radio Plays\"))"))
    }

    /// Every tile of a deck in the same size: a long title takes a second
    /// line instead of shrinking (seen at the standard size: "Listening
    /// History" stood smaller than its neighbours).
    @Test("ein Kacheltitel schrumpft nie: mehrere Woerter brechen am Leerzeichen, neben einem einzelnen Wort darf die Zahl unter den Titel ruecken", .needsTheSources)
    func aLongTitleWrapsInsteadOfShrinking() throws {
        let data = try Data(contentsOf: SourceTree.root.appendingPathComponent("Sources/Localizable.xcstrings"))
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let strings = try #require(json["strings"] as? [String: [String: Any]])
        func german(_ key: String) throws -> String {
            try #require(((strings[key]?["localizations"] as? [String: Any])?["de"] as? [String: Any])
                .flatMap { $0["stringUnit"] as? [String: Any] }?["value"] as? String, "no German value for \(key)")
        }
        for single in ["Downloaded", try german("Downloaded"), try german("Listening History")] {
            #expect(CategoryTile.titleLines(single) == 1, "the single word \(single) may be hyphenated")
            #expect(CategoryTile.countMayMoveBelow(single), "the count of \(single) stays beside it and squeezes it")
        }
        #expect(CategoryTile.titleLines("Listening History") == 2, "several words do not wrap at the space")
        #expect(!CategoryTile.countMayMoveBelow("Listening History"))
        let tile = SyncContractFenceTests.stripped(try sourceText("Sources/Views/CategoryTile.swift"))
        #expect(!tile.contains("minimumScaleFactor"), "a tile title shrinks again")
        #expect(tile.contains("MeasuredFits {"), "the count does not move by the measured row")
    }
}
#endif
