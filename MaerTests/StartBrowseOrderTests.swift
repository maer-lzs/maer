// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Foundation
import Testing
@testable import Maer

/// Browse leads with the three kinds: the first three tiles on Start show an
/// audiobook, a show and music, as far as they are switched on; the book
/// share alternates audiobook and radio play, an audiobook first; the music
/// share carries Musopen as its third lane; the Browse page orders its
/// areas the same way, books first.
struct StartBrowseOrderTests {
    private func feed(_ n: Int) -> HoerspielCuration.Entry {
        .init(title: "F\(n)", author: "A", feedURL: "https://f/\(n)")
    }

    private func item(_ id: String) -> LibraryItem { LibraryItem(id: id, media: nil, addedAt: nil) }

    @Test("the shares go books, shows, music, so the first three tiles show the three kinds")
    func firstThreeKinds() {
        let shares = BrowseMix.startShares(recommended: ["show1", "show2"], music: ["music1", "music2"],
                                           books: ["book1", "book2"])
        #expect(BrowseMix.interleave(shares, limit: 6).prefix(3) == ["book1", "show1", "music1"])
        // A share switched off falls away and the order of the rest stays.
        let noShows = BrowseMix.startShares(recommended: [], music: ["music1"], books: ["book1"])
        #expect(BrowseMix.interleave(noShows, limit: 6) == ["book1", "music1"])
    }

    @Test("the book share alternates audiobook and radio play, an audiobook first")
    func audiobookFirst() {
        let tiles = CatalogMix.alternating(audiobooks: [[item("lv:1"), item("lv:2")], [item("ia:1")], [item("gut:1")]],
                                           radioFeeds: [[feed(1)], [feed(2)]], radioItems: [[item("otr:1")]],
                                           limit: 12, seed: 7, previous: [])
        let ids = tiles.map(\.id)
        let audiobooks: Set = ["item:lv:1", "item:lv:2", "item:ia:1", "item:gut:1"]
        #expect(audiobooks.contains(ids[0]), "the first tile is no audiobook: \(ids)")
        #expect(!audiobooks.contains(ids[1]), "the second tile is no radio play: \(ids)")
        #expect(audiobooks.contains(ids[2]) && !audiobooks.contains(ids[3]), "\(ids)")
        #expect(ids.count == 7, "a tile was lost: \(ids)")
        // Without radio plays the audiobooks stand alone, and the other way.
        #expect(CatalogMix.alternating(audiobooks: [], radioFeeds: [[feed(1)]], radioItems: [],
                                       limit: 12, seed: 7, previous: []).map(\.id) == ["feed:https://f/1"])
    }

    @Test("the Browse page leads with the books, then the shows, then the music")
    func pageOrder() {
        #expect(BrowseSection.Group.allCases == [.books, .podcasts, .music])
        #expect(BrowseSection.allCases.first == .librivox)
        let groups = BrowseSection.allCases.map(\.group)
        #expect(groups == groups.sorted { BrowseSection.Group.allCases.firstIndex(of: $0)! < BrowseSection.Group.allCases.firstIndex(of: $1)! },
                "a section stands outside its area: \(groups)")
    }

    @Test("Start's music share carries Musopen, and its row names Musopen among its sources", .needsTheSources)
    func musopenOnStart() throws {
        let home = SyncContractFenceTests.stripped(try SourceTree.text(SourceTree.root.appendingPathComponent("Sources/Views/HomeView.swift")))
        #expect(home.contains("AppStorageKeys.musopenActive ? CatalogMix.ordered(rows.musopen, for: .musicHome) : []"))
        #expect(home.contains("return BrowseMix.startShares(recommended: recommended, music: music, books: books)"))
        #expect(AppRows.row(key: "home.discoverMusic")?.sourceKeys.contains("musopen") == true)
    }
}
#endif
