// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
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
        // SECHS, und der Satz oben stimmt seit T45 wirklich: „Geladen" stand
        // nur auf dem Tab, der Zaun prueste fuenf und behauptete sechs.
        #expect(searchTitles.count == 6, "das Such-Deck traegt nicht sechs Eintraege")
        for title in ["Artists", "Albums", "Songs", "Playlists", "Genres", "Downloaded"] {
            #expect(searchTitles.contains(String(localized: String.LocalizationValue(title))),
                    "entry \(title) missing on the search deck")
            #expect(music.contains("\"\(title)\""), "entry \(title) missing on the music tab")
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
        // Der Zeuge haengt seit T45 an einer Kachel, die es noch gibt: die
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
}
#endif
