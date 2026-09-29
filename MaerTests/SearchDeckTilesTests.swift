// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// Which entry points the browse deck offers, and where they lead. This used
/// to live in the search view as closures, where no test could reach it: a
/// tile that led nowhere, or a library tile that navigated instead of
/// switching the scope, would only have shown at the finger.
struct SearchDeckTilesTests {
    private let counts = SearchDeckCounts(authors: 7, series: 3, genres: 5,
                                          shows: 11, albums: 42, artists: 9)

    @Test("Der Buecher-Bereich bietet Autoren, Reihen und Genres mit ihrem Bestand")
    func audiobooksOfferTheThreeGroups() {
        let tiles = SearchDeckTiles.tiles(scope: .audiobooks, counts: counts)
        #expect(tiles.map(\.id) == ["authors", "series", "genres"])
        #expect(tiles.map(\.count) == [7, 3, 5])
        #expect(tiles.map(\.destination) == [.group(.authors), .group(.series), .group(.genres)])
    }

    @Test("Podcasts und Radio haben keine Kacheln, dort ist die Sendung selbst die Einheit")
    func podcastsAndRadioHaveNoTiles() {
        #expect(SearchDeckTiles.tiles(scope: .podcasts, counts: counts).isEmpty)
        #expect(SearchDeckTiles.tiles(scope: .radio, counts: counts).isEmpty)
    }

    @Test("Der Musik-Bereich fuehrt auf die Seiten, nicht auf einen Bereichswechsel")
    func musicTilesLeadToThePages() {
        let tiles = SearchDeckTiles.tiles(scope: .music, counts: counts)
        #expect(tiles.map(\.id) == ["artists", "music-albums", "music-songs",
                                    "music-playlists", "music-genres", "music-downloaded"])
        #expect(tiles.map(\.destination) == [.artists, .albums, .songs, .playlists, .genres, .downloaded])
        // The stock renders where the deck holds it; the pages load fresh.
        #expect(tiles.map(\.count) == [9, 42, nil, nil, nil, 0])
    }

    @Test("Geladen steht als sechste Kachel und traegt die Zahl der Zaehlung")
    func downloadedStandsAsTheSixthTile() {
        var mit = counts
        mit.downloaded = 7
        let tiles = SearchDeckTiles.tiles(scope: .music, counts: mit)
        #expect(tiles.count == 6)
        let geladen = tiles.last
        #expect(geladen?.id == "music-downloaded")
        #expect(geladen?.destination == .downloaded)
        #expect(geladen?.count == 7, "die Kachel erfindet ihre Zahl statt sie zu reichen")
        // Das freie Regal ist hier weg, auf BEIDEN Flaechen.
        #expect(!tiles.contains { $0.id == "music-free-classical" })
    }

    @Test("Der gemischte Bereich WECHSELT den Bereich, statt zu navigieren")
    func theLibraryScopeSwitchesInsteadOfNavigating() {
        let tiles = SearchDeckTiles.tiles(scope: .library, counts: counts)
        #expect(tiles.map(\.id) == ["authors", "series", "genres", "shows", "artists", "albums"])
        // This is the difference that would break silently: on the library
        // scope shows and albums lead to their scope, not to a music page.
        #expect(tiles.first { $0.id == "shows" }?.destination == .scope(.podcasts))
        #expect(tiles.first { $0.id == "albums" }?.destination == .scope(.music))
        #expect(tiles.first { $0.id == "albums" }?.destination != .albums)
        // And the free shelf is a MUSIC entry, it does not creep in here.
        #expect(!tiles.contains { $0.id == "music-free-classical" })
    }

    @Test("Ohne Antwort der Musikquelle steht GAR KEINE Ziffer, keine erfundene Null")
    func artistCountWithoutAnAnswerShowsNoNumeral() {
        // Eine 0 waere eine Zahl, die das Deck nicht weiss: solange die
        // Quelle offline ist oder scheitert, antwortet sie nie, und die
        // Kachel wuerde behaupten, es gebe keine Kuenstler. Die Kachel
        // verbirgt die Ziffer bei nil, der Musik-Tab haelt dieselbe Regel.
        let none = SearchDeckTiles.tiles(scope: .music, counts: SearchDeckCounts()).first
        #expect(none?.id == "artists")
        #expect(none?.count == nil)
        // Und mit Antwort steht die Zahl, auch die Null einer leeren Quelle.
        let empty = SearchDeckTiles.tiles(scope: .music, counts: SearchDeckCounts(artists: 0)).first
        #expect(empty?.count == 0)
        let answered = SearchDeckTiles.tiles(scope: .music, counts: counts).first
        #expect(answered?.count == 9)
    }

    @Test("Jede Kachel jedes Bereichs hat eine Kennung und ein benanntes Ziel")
    func everyTileHasAnIdAndATarget() {
        var ids: Set<String> = []
        var targets: Set<SearchDeckDestination> = []
        for scope in SearchScope.allCases {
            let tiles = SearchDeckTiles.tiles(scope: scope, counts: counts)
            for tile in tiles {
                #expect(!tile.id.isEmpty)
                #expect(!tile.title.isEmpty)
                #expect(!tile.systemImage.isEmpty)
                ids.insert(tile.id)
                targets.insert(tile.destination)
            }
            // No scope shows the same entry point twice.
            #expect(Set(tiles.map(\.id)).count == tiles.count, "duplicate tile in \(scope.rawValue)")
        }
        // Eleven entry points over all scopes, and each one leads somewhere of
        // its own: a new destination that no scope offers, or two tiles that
        // secretly share a target, shows up here.
        #expect(ids.count == 11)
        #expect(targets.count == 11)
    }
}
#endif
