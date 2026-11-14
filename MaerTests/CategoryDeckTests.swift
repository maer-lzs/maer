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

    @Test("a single tile in the last row takes the full width, and the grid asks the rule", .needsTheSources)
    func aLoneLastTileSpansTheRow() throws {
        #expect(DeckRows.lastSpansAll(count: 3, columns: 2), "the books tab deck: series, authors, local files")
        #expect(!DeckRows.lastSpansAll(count: 4, columns: 2), "a full last row spans nothing")
        #expect(!DeckRows.lastSpansAll(count: 3, columns: 1), "one column needs no span")
        #expect(DeckRows.lastSpansAll(count: 1, columns: 2), "a deck of one tile takes the row")
        #expect(!DeckRows.lastSpansAll(count: 0, columns: 2))
        #expect(!DeckRows.lastSpansAll(count: 5, columns: 3), "two in a row of three are no single tile")
        let grid = FetchAnswerTests.squeezed(try sourceText("Sources/Views/CategoryTile.swift"))
        #expect(grid.contains("let spans = DeckRows.lastSpansAll(count: entries.count, columns: columns.count)")
                    && grid.contains("if spans, let last = entries.last { tile(last) }"),
                "the deck lays its last tile out without the rule")
    }

    @Test("search page and music tab render the same tile list with the same entries", .needsTheSources)
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
        // SIX on both surfaces: if „Geladen“ stands only on the tab, the
        // fence checks five and claims six.
        #expect(searchTitles.count == 6, "das Such-Deck traegt nicht sechs Eintraege")
        for title in ["Artists", "Albums", "Songs", "Playlists", "Genres", "Downloads list"] {
            #expect(searchTitles.contains(String(localized: String.LocalizationValue(title))),
                    "entry \(title) missing on the search deck")
            #expect(music.contains("\"\(title)\""), "entry \(title) missing on the music tab")
        }
    }

    /// The radio genres were a hand-built copy of the tile. They render the
    /// one deck now and keep their journey handles.
    @Test("The radio genres render the same tile grid, not one of their own", .needsTheSources)
    func theRadioGenresRenderTheOneDeck() throws {
        let radio = try sourceText("Sources/Views/Radio/RadioView.swift")
        #expect(radio.contains("CategoryDeckGrid(entries: RadioCatalog.genres"), "the radio genres left the deck")
        #expect(!radio.contains("LazyVGrid"), "the radio tab grew a tile grid of its own again")
        #expect(radio.contains("accessibilityId: \"radio-genre-\\(genre.tag)\""), "the journey handle of a genre tile changed")
    }

    /// At AX3 on a 393 pt phone two columns cut even a short title
    /// ("Nac…", "Mu…", measured in the picture). Every grid of category
    /// tiles takes its columns from the one rule.
    @Test("tile grid: two columns, one in the accessibility sizes, and every grid asks the same rule", .needsTheSources)
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

    /// The identifiers a journey names literally are COMPOSED: the grid puts
    /// `deck-tier-` in front of the tile's identifier.
    /// A text search in the sources therefore does not find them, and a
    /// checker that counts strings takes them for dead. They are not, and
    /// this case holds both halves so that the promise
    /// stands even when no journey runs.
    @Test("The composed tile identifiers really come into being", .needsTheSources)
    func theComposedTileIdentifiersExist() throws {
        // First half, at the behaviour: the tile carries the identifier the
        // journey builds its own from.
        // The witness hangs on a tile that still exists: the
        // free classical tile is gone on both surfaces, the promise
        // about the composed identifier holds unchanged.
        let ids = Set(SearchDeckTiles.tiles(scope: .music, counts: SearchDeckCounts()).map(\.id))
        #expect(ids.contains("music-downloaded"))
        #expect(!ids.contains("music-free-classical"), "die freie Kachel ist zurueck")
        // Second half, at the source text: the grid puts exactly this
        // prefix in front when the tile brings no identifier of its own.
        let grid = try sourceText("Sources/Views/CategoryTile.swift")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
        #expect(grid.contains("entry.accessibilityId ?? \"deck-tier-\\(entry.id)\""))
    }

    @Test("A number is shown only where it is known")
    func countOnlyWhereKnown() {
        let entry = CategoryDeckEntry(id: "songs", title: "Songs", systemImage: "music.note", count: nil) {}
        #expect(entry.count == nil)
        #expect(entry.accessibilityId == nil, "the grid derives the handle from the id")
    }

    /// The search tile carries the short title; VoiceOver says the full one.
    @Test("the search tile is called Hoerbuecher in short and gives VoiceOver the full title", .needsTheSources)
    func theSearchTileSaysTheFullTitle() throws {
        let search = try sourceText("Sources/Views/SearchScreen.swift")
        #expect(search.contains("CategoryTile(title: String(localized: \"Audiobooks\")"))
        #expect(search.contains(".accessibilityLabel(Text(\"Audiobooks and Radio Plays\"))"))
    }

    /// Every list of downloaded titles is called "Downloads" in English, the
    /// state on a cover stays "Downloaded"; German says "Geladen" for both.
    /// At XXXL the count stands under the title in every tile of a deck.
    @Test("every list of downloaded titles is called Downloads in English, the state on the cover Downloaded; at XXXL the count sits under the title in every tile", .needsTheSources)
    func downloadListsAreCalledDownloads() throws {
        let data = try Data(contentsOf: SourceTree.root.appendingPathComponent("Sources/Localizable.xcstrings"))
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let strings = try #require(json["strings"] as? [String: [String: Any]])
        func value(_ key: String, _ language: String) -> String? {
            ((strings[key]?["localizations"] as? [String: Any])?[language] as? [String: Any])
                .flatMap { $0["stringUnit"] as? [String: Any] }?["value"] as? String
        }
        #expect(value("Downloads list", "en") == "Downloads")
        #expect(value("Downloads list", "de") == "Geladen")
        #expect(value("Downloaded", "de") == "Geladen")
        let lists = ["Sources/CarPlay/CarPlaySceneDelegate.swift",
                     "Sources/Models/SearchDeckTiles.swift", "Sources/Models/AppRows.swift", "Sources/Views/PodcastsView.swift",
                     "Sources/Views/LibraryView.swift", "Sources/Views/Music/MusicView.swift", "Sources/Views/Music/MusicLibraryPages.swift"]
        for path in lists {
            let code = SyncContractFenceTests.stripped(try sourceText(path))
            #expect(!code.contains("\"Downloaded\""), "\(path) still titles a list Downloaded")
            #expect(code.contains("\"Downloads list\""), "\(path) lost its list title")
        }
        for path in ["Sources/Views/CoverBadge.swift", "Sources/Views/DetailHeader.swift"] {
            #expect(try sourceText(path).contains("Text(\"Downloaded\")"), "\(path) no longer says the cover state")
        }
        // The filter of the books tab names a state, like Finished.
        #expect(try sourceText("Sources/ViewModels/LibraryViewModel.swift").contains("case .heruntergeladen: return String(localized: \"Downloaded\")"),
                "the filter is called like a list")
        #expect(CategoryTile.countBelowInEveryTile(.xxxLarge))
        #expect(!CategoryTile.countBelowInEveryTile(.xxLarge) && !CategoryTile.countBelowInEveryTile(.accessibility3))
    }

    /// Every tile of a deck in the same size: a long title takes a second
    /// line instead of shrinking (seen at the standard size: "Listening
    /// History" stood smaller than its neighbours).
    @Test("a tile title never shrinks: several words break at the space, next to a single word the count may move under the title", .needsTheSources)
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
