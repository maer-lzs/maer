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
        let searchTitles = Set(SearchDeckTiles.tiles(scope: .music, counts: SearchDeckCounts(),
                                                     shellacActive: false).map(\.title))
        for title in ["Artists", "Albums", "Songs", "Playlists", "Genres"] {
            #expect(searchTitles.contains(String(localized: String.LocalizationValue(title))),
                    "entry \(title) missing on the search deck")
            #expect(music.contains("\"\(title)\""), "entry \(title) missing on the music tab")
        }
    }

    @Test("Eine Zahl steht nur, wo sie bekannt ist")
    func countOnlyWhereKnown() {
        let entry = CategoryDeckEntry(id: "songs", title: "Songs", systemImage: "music.note", count: nil) {}
        #expect(entry.count == nil)
        #expect(entry.accessibilityId == nil, "the grid derives the handle from the id")
    }
}
#endif
