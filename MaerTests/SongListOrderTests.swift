// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// The song list with two servers is ordered as a whole in every sort
/// the album grid offers, the Navidrome list kept on the device says how
/// old it is, and a failure is a sentence.
@MainActor
struct SongListOrderTests {
    private static func squeezed(_ raw: String) -> String {
        SyncContractFenceTests.stripped(raw)
            .split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    private static func source(_ relative: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        return squeezed(try String(contentsOf: root.appendingPathComponent(relative), encoding: .utf8))
    }

    static func song(_ id: String, _ title: String, artist: String? = nil, added: Double? = nil,
                     played: Double? = nil, plays: Int? = nil) -> MusicTopSong {
        let item = LibraryItem(id: id, media: LibraryItemMedia(
            metadata: LibraryItemMetadata(title: title, authorName: artist, narratorName: nil, seriesName: nil,
                                          genres: nil, publishedYear: nil, description: nil),
            duration: nil, chapters: nil, tracks: nil), addedAt: nil)
        return MusicTopSong(item: item, albumName: nil, addedAt: added, lastPlayedAt: played, playCount: plays)
    }

    static func ids(_ songs: [MusicTopSong]) -> [String] { songs.map(\.id) }

    // MARK: - The order

    @Test("GT-2: jede Ordnung der Alben ordnet auch Titel, Unbekanntes zuletzt, Gleichstand nach Titel und Kennung")
    func everySortOrdersSongs() {
        let songs = [
            Self.song("s1", "Zebra", artist: "Beta", added: 100, played: 50, plays: 3),
            Self.song("s2", "Alpha", artist: "Alpha", added: 300, played: nil, plays: 9),
            Self.song("s3", "Mitte", artist: "alpha", added: nil, played: 90, plays: nil),
            Self.song("s4", "Alpha", artist: "Gamma", added: 300, played: 90, plays: 3),
        ]
        // Measured: `localizedStandardCompare` puts "alpha" before "Alpha";
        // only the same name twice falls through to the next rule.
        #expect(Self.ids(SongOrder.sorted(songs, by: .nameAZ)) == ["s2", "s4", "s3", "s1"],
                "the same title twice, the id decides")
        #expect(Self.ids(SongOrder.sorted(songs, by: .kuenstler)) == ["s3", "s2", "s1", "s4"],
                "lower case before upper case, as the album grid orders")
        #expect(Self.ids(SongOrder.sorted(songs, by: .neu)) == ["s2", "s4", "s1", "s3"],
                "newest first, a tie by title, the unknown date last")
        #expect(Self.ids(SongOrder.sorted(songs, by: .zuletztGespielt)) == ["s4", "s3", "s1", "s2"],
                "last played first, never played last")
        #expect(Self.ids(SongOrder.sorted(songs, by: .meistgespielt)) == ["s2", "s4", "s1", "s3"],
                "most plays first, a tie by title, no count last")
    }

    @Test("GT-2: eine sortierte und eine unsortiert gegebene Quelle ergeben im Verbund eine geordnete Liste, in jeder Ordnung")
    func twoServersMergeIntoOneOrder() async throws {
        let sub = MusicUnionTests.Stand(prefix: "sub:", titles: [])
        let jf = MusicUnionTests.Stand(prefix: "jf:", titles: [])
        // Navidrome hands its songs out in its own order: given here unsorted.
        sub.songs = [
            Self.song("sub:song:3", "Kiesel", artist: "Cure", added: 30, played: 5, plays: 1),
            Self.song("sub:song:1", "Wasserfall", artist: "Abba", added: 10, played: 40, plays: 7),
            Self.song("sub:song:2", "Birke", artist: "Muse", added: 50, played: nil, plays: 2),
        ]
        jf.songs = [
            Self.song("jf:song:a", "Anker", artist: "Björk", added: 40, played: 20, plays: 4),
            Self.song("jf:song:b", "Nebel", artist: "Dylan", added: nil, played: 60, plays: nil),
        ]
        let all = sub.songs + jf.songs
        for sort in MusicSortOption.allCases {
            let union = MusicUnion(sources: [sub, jf])
            let first = try await union.songPage(offset: 0, size: 3, sort: sort)
            let rest = try await union.songPage(offset: 3, size: 3, sort: sort)
            #expect(Self.ids(first + rest) == Self.ids(SongOrder.sorted(all, by: sort)), "\(sort)")
        }
    }

    @Test("GT-2: Serverdaten mit neun Nachkommastellen, mit und ohne Zone, Unlesbares ist nil")
    func serverDatesAreRead() {
        let navidrome = SongOrder.seconds("2025-03-26T22:26:49.315688846Z")
        #expect(navidrome == SongOrder.seconds("2025-03-26T22:26:49Z"))
        #expect(navidrome != nil)
        #expect(SongOrder.seconds("2025-03-26T23:26:49.5+01:00") == navidrome)
        #expect(SongOrder.seconds("gestern") == nil)
        #expect(SongOrder.seconds("") == nil && SongOrder.seconds(nil) == nil)
    }

    // MARK: - The kept list

    static func catalog(created: [String?], whole: Double, count: Int? = 3, scan: String? = "s1") -> SongCatalog {
        SongCatalog(entries: created.enumerated().map { index, created in
            SongCatalog.Entry(id: "\(index)", title: "t\(index)", artist: nil, album: nil, albumId: nil,
                              duration: nil, created: created, played: nil, playCount: nil)
        }, wholeAt: whole, serverCount: count, serverLastScan: scan)
    }

    @Test("GT-2: einmal ganz, danach nur Neues; weniger Titel, sieben Tage oder kein Wasserzeichen heisst ganz")
    func theKeptListStep() {
        let day = 86_400.0
        let now = 1_800_000_000.0
        let kept = Self.catalog(created: ["2025-03-26T22:26:49Z", "2025-04-01T10:00:00.123456789Z", nil], whole: now - day)
        #expect(SongCatalogRule.step(kept: nil, count: 3, lastScan: "s1", now: now) == .whole)
        #expect(SongCatalogRule.step(kept: kept, count: 3, lastScan: "s1", now: now) == .keep)
        let newest = SongOrder.seconds("2025-04-01T10:00:00Z")!
        #expect(SongCatalogRule.step(kept: kept, count: 5, lastScan: "s2", now: now) == .addNew(since: newest),
                "more songs: only what came after the newest one held")
        #expect(SongCatalogRule.step(kept: kept, count: 3, lastScan: "s2", now: now) == .addNew(since: newest),
                "a new scan with the same count may still have replaced songs")
        #expect(SongCatalogRule.step(kept: kept, count: 2, lastScan: "s2", now: now) == .whole, "fewer: something left")
        let old = Self.catalog(created: ["2025-03-26T22:26:49Z"], whole: now - 7 * day)
        #expect(SongCatalogRule.step(kept: old, count: 3, lastScan: "s1", now: now) == .whole, "seven days: whole again")
        #expect(SongCatalogRule.step(kept: kept, count: nil, lastScan: nil, now: now) == .whole,
                "no scan status and a day old: whole")
        let fresh = Self.catalog(created: ["2025-03-26T22:26:49Z"], whole: now - 60)
        #expect(SongCatalogRule.step(kept: fresh, count: nil, lastScan: nil, now: now) == .keep)
        let noDates = Self.catalog(created: [nil, nil], whole: now - 60)
        #expect(SongCatalogRule.step(kept: noDates, count: 9, lastScan: "s2", now: now) == .whole,
                "without a watermark nothing new can be asked for")
        #expect(SongCatalogRule.step(kept: Self.catalog(created: [], whole: now), count: 3, lastScan: "s1", now: now) == .whole)
    }

    @Test("GT-2: Neues kommt dazu, ein schon gehaltener Titel wird ersetzt, der Stand des Servers wird vermerkt")
    func addingNewSongs() {
        let kept = Self.catalog(created: ["2025-03-26T22:26:49Z", nil], whole: 5)
        let replaced = SongCatalog.Entry(id: "1", title: "neu", artist: nil, album: nil, albumId: nil,
                                         duration: nil, created: nil, played: nil, playCount: 4)
        let added = SongCatalog.Entry(id: "9", title: "dazu", artist: nil, album: nil, albumId: nil,
                                      duration: nil, created: nil, played: nil, playCount: nil)
        let next = SongCatalogRule.adding([replaced, added], to: kept, count: 4, lastScan: "s2")
        #expect(next.entries.map(\.id) == ["0", "1", "9"])
        #expect(next.entries.first { $0.id == "1" }?.title == "neu")
        #expect(next.serverCount == 4 && next.serverLastScan == "s2")
        #expect(next.wholeAt == 5, "adding is not a whole load")
    }

    // MARK: - The servers and the page

    @Test("GT-2: Jellyfin sortiert am Server nach derselben Regel, der Name zuletzt und aufsteigend, nie SortName")
    func jellyfinSortsTheSameWay() {
        #expect(JellyfinProvider.songSort(.nameAZ) == ("Name", "Ascending"))
        #expect(JellyfinProvider.songSort(.kuenstler) == ("Artist,Name", "Ascending,Ascending"))
        #expect(JellyfinProvider.songSort(.neu) == ("DateCreated,Name", "Descending,Ascending"))
        #expect(JellyfinProvider.songSort(.zuletztGespielt) == ("DatePlayed,Name", "Descending,Ascending"))
        #expect(JellyfinProvider.songSort(.meistgespielt) == ("PlayCount,Name", "Descending,Ascending"))
        for sort in MusicSortOption.allCases {
            #expect(!JellyfinProvider.songSort(sort).sortBy.contains("SortName"),
                    "a song's SortName is disc, track and name")
        }
    }

    /// The five answers of the Jellyfin test bench (`jellyfin-demo`, 76
    /// songs), fetched with `Name` as the server sort, trimmed to the fields
    /// the order reads and decoded through the app's own `JFItemsResult`.
    static func benchAnswer(_ file: String) throws -> [JFItem] {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let data = try Data(contentsOf: root.appendingPathComponent("Fixtures/JellyfinSongOrder/\(file)"))
        return try JSONDecoder().decode(JFItemsResult.self, from: data).items ?? []
    }

    static let benchFiles: [(MusicSortOption, String)] = [
        (.nameAZ, "1-name.json"), (.kuenstler, "2-artist-name.json"), (.neu, "3-datecreated-name.json"),
        (.zuletztGespielt, "4-dateplayed-name.json"), (.meistgespielt, "5-playcount-name.json"),
    ]

    static func misorderedPairs(_ songs: [MusicTopSong], by sort: MusicSortOption) -> Int {
        guard songs.count > 1 else { return 0 }
        return (1..<songs.count).filter { SongOrder.inOrder(songs[$0], songs[$0 - 1], by: sort) }.count
    }

    @Test("GT2-1: die Seite des Pruefstands, durch den Anbieter gegeben, ist in jeder Ordnung dieselbe wie nach SongOrder")
    func theBenchPageIsInSongOrder() throws {
        var serverMisordered = 0
        for (sort, file) in Self.benchFiles {
            let items = try Self.benchAnswer(file)
            try #require(items.count == 76, "the bench answer holds its 76 songs: \(file)")
            // The precondition: the server's own order is not already the
            // app's, otherwise this case would pass for any page rule.
            serverMisordered += Self.misorderedPairs(items.map(JellyfinProvider.topSong(from:)), by: sort)
            let page = JellyfinProvider.songPage(from: items, sort: sort)
            #expect(Self.ids(page) == Self.ids(SongOrder.sorted(page, by: sort)), "\(file)")
            #expect(Self.misorderedPairs(page, by: sort) == 0, "\(file)")
        }
        #expect(serverMisordered == 17, "measured: 5, 1, 0, 5 and 6 pairs in the server's Name order")
    }

    @Test("GT-2: Navidrome sortiert auf dem Geraet, ein Fehlschlag ist ein Satz, die Seite nennt den Stand")
    func theWiring() throws {
        let subsonic = try Self.source("Sources/Providers/SubsonicProvider.swift")
        #expect(subsonic.contains("sorted = SongOrder.sorted(catalog.entries.map(Self.topSong(from:)), by: sort)"))
        #expect(subsonic.contains("if let kept = songCatalogKept { return kept } throw error"),
                "a kept list stays on a failure, without one the failure goes up")
        #expect(subsonic.contains("try await Ablage.documents.save(next, name: name)"))
        let page = try Self.source("Sources/Views/Music/MusicLibraryPages.swift")
        #expect(page.contains("MusicPageLoad.run(\"songs offset=\\(offset)\", reachable: provider.isAvailable,"))
        #expect(page.contains("try await provider.songPage(offset: offset, size: pageSize, sort: musicSort)"))
        #expect(page.contains("errorText = outcome.failure"),
                "a failure is a sentence, through the one rule (MusicPageLoad, witness MusicPageStateTests)")
        #expect(page.contains("wholeAt = provider.songListWholeAt"))
        #expect(!page.contains("try? await AppSession.shared.musicProvider .songPage("), "no swallowed song page")
        let union = try Self.source("Sources/Providers/MusicUnion.swift")
        #expect(union.components(separatedBy: "genre not asked of source").count - 1 == 2,
                "a server not asked for a genre says so, on both genre lists")
    }
}
#endif
