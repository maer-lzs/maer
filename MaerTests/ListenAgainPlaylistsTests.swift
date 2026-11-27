// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// Every heard playlist of music stands in "Listen Again": a server
/// playlist once it has a moment (started, finished or shuffled from its
/// card), an own list whose home is music by the moment this device last
/// heard it. Start, the page behind the row and the car read one row, and
/// "Remove from Listen Again" holds for both kinds.
@MainActor
struct ListenAgainPlaylistsTests {
    private static func progress(_ fraction: Double, finished: Bool = false, at ms: Double) -> BookProgress {
        BookProgress(fraction: fraction, isFinished: finished, lastUpdate: ms)
    }

    private static func kinds(_ id: String) -> RecentlyPlayedRow.MusicKind? {
        id.hasPrefix("pl:") ? .playlist : id.hasPrefix("al:") ? .album : nil
    }

    @Test("an own list stands by its moment between an album and a station")
    func anOwnListByItsMoment() {
        let row = RecentlyPlayedRow.merged(albums: ["al:1"], albumTimes: ["al:1": 300], continued: [],
                                           stations: ["st:1"], stationTimes: ["st:1": 100],
                                           ownLists: ["list-a": 200], limit: 12)
        #expect(row == [.album(id: "al:1"), .ownList(id: "list-a"), .station(id: "st:1")])
    }

    @Test("only own lists whose home is music and that were heard stand; a list gone from the store does not")
    func onlyHeardMusicLists() {
        let lists: [(id: String, home: PlaylistHome)] = [("music-heard", .music), ("music-never", .music),
                                                         ("start-heard", .start), ("podcasts-heard", .podcasts)]
        let plays = ["music-heard": 2_000_000.0, "start-heard": 2_000_000, "podcasts-heard": 2_000_000,
                     "gone": 2_000_000]
        #expect(RecentlyPlayedRow.ownListTimes(lists, plays: plays, hidden: [:]) == ["music-heard": 2_000])
    }

    @Test("Remove from Listen Again holds for an own list until it is heard again")
    func removingAnOwnList() {
        let lists: [(id: String, home: PlaylistHome)] = [("a", .music)]
        let hidden = ContinueHidden.hiding(id: "a", lastUpdate: 2_000_000, in: [:])
        #expect(RecentlyPlayedRow.ownListTimes(lists, plays: ["a": 2_000_000], hidden: hidden).isEmpty)
        #expect(RecentlyPlayedRow.ownListTimes(lists, plays: ["a": 3_000_000], hidden: hidden) == ["a": 3_000])
    }

    @Test("a server playlist with a moment is a candidate, started, finished or shuffled; a finished album is not")
    func serverPlaylistCandidates() {
        let progress = ["pl:finished": Self.progress(1, finished: true, at: 5_000_000),
                        "pl:started": Self.progress(0.4, at: 4_000_000),
                        "al:finished": Self.progress(1, finished: true, at: 5_000_000),
                        "al:started": Self.progress(0.4, at: 4_000_000)]
        let candidates = RecentlyPlayedRow.musicCandidates(progress: progress, kind: Self.kinds,
                                                           plays: ["pl:shuffled": 6_000_000], hidden: [:])
        #expect(Set(candidates) == ["pl:finished", "pl:started", "al:started", "pl:shuffled"])
    }

    @Test("Remove from Listen Again holds for a server playlist until a newer moment")
    func removingAServerPlaylist() {
        let progress = ["pl:1": Self.progress(1, finished: true, at: 5_000_000)]
        let hidden = ContinueHidden.hiding(id: "pl:1", lastUpdate: 5_000_000, in: [:])
        #expect(RecentlyPlayedRow.musicCandidates(progress: progress, kind: Self.kinds, plays: [:], hidden: hidden).isEmpty)
        #expect(RecentlyPlayedRow.musicCandidates(progress: progress, kind: Self.kinds, plays: ["pl:1": 6_000_000],
                                                  hidden: hidden) == ["pl:1"])
    }

    @Test("the moments keep the newest fifty, and hearing a list again replaces its moment")
    func theMomentsKeepTheNewest() {
        var moments: [String: Double] = [:]
        for index in 0..<60 { moments = PlaylistPlays.noting("l\(index)", atMs: Double(index + 1), in: moments) }
        #expect(moments.count == PlaylistPlays.keep)
        #expect(moments["l0"] == nil && moments["l59"] == 60)
        moments = PlaylistPlays.noting("l59", atMs: 100, in: moments)
        #expect(moments["l59"] == 100 && moments.count == PlaylistPlays.keep)
    }

    @Test("a stored form this build does not know, or a broken one, reads as none and touches no list; the next moment is written")
    func anUnknownStoredFormReadsAsNone() throws {
        let suite = "playlist-plays-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        for raw: Any in [["a", "b"], "kaputt", ["a": "morgen"], Data([0, 1]), ["v": 2, "moments": ["a": 1]]] {
            defaults.set(raw, forKey: AppStorageKeys.playlistPlays)
            #expect(PlaylistPlaysStore.moments(defaults: defaults).isEmpty, "\(raw) was read as moments")
        }
        #expect(PlaylistPlays.decoded(["a": 1_000.0, "b": "x"]) == ["a": 1_000], "a valid entry beside a broken one is lost")
        PlaylistPlaysStore.note("a", atMs: 2_000, defaults: defaults)
        #expect(PlaylistPlaysStore.moments(defaults: defaults) == ["a": 2_000])
    }

    @Test("starting an own list notes its moment on this device")
    func startingAListNotesItsMoment() async throws {
        let before = UserDefaults.standard.object(forKey: AppStorageKeys.playlistPlays)
        defer { UserDefaults.standard.set(before, forKey: AppStorageKeys.playlistPlays) }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("plays-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = MaerPlaylists(database: MaerDatabase(path: directory.appendingPathComponent("maer.sqlite").path))
        let list = store.create(name: "Abends")
        // A catalogue id plays from itself, without a server.
        _ = store.add(itemId: "jam:1", to: list.id)
        let current = try #require(store.playlist(id: list.id))
        let coordinator = PlayerCoordinator(provider: MockProvider())
        let since = Date().timeIntervalSince1970 * 1000
        let started = await RoutinePlayback.start(current, in: store, on: coordinator)
        try #require(started, "the list did not start: the case measures nothing")
        let moment = try #require(PlaylistPlaysStore.moments()[list.id], "no moment for the list")
        #expect(moment >= since)
    }

    @Test("Fence: shuffling a server playlist from its card notes the playlist's moment", .needsTheSources)
    func shufflingFromTheCardNotes() throws {
        let card = try FetchAnswerTests.squeezedSource("Sources/Views/Music/PlaylistCard.swift")
        #expect(card.contains("let pool = await CollectionSongs.serverPool(itemId) if !pool.items.isEmpty { PlaylistPlaysStore.note(itemId) }"),
                "the server playlist's shuffle leaves no moment")
        #expect(card.contains("let pool = ShufflePool.of(start.items, resuming: start.fromRule) if !start.items.isEmpty { PlaylistPlaysStore.note(list.id) }"),
                "an own list's shuffle leaves no moment")
    }

    @Test("Fence: Start, the page behind the row and the car read the one row", .needsTheSources)
    func oneRowForStartPageAndCar() throws {
        let home = try FetchAnswerTests.squeezedSource("Sources/Views/HomeView.swift")
        let page = try FetchAnswerTests.squeezedSource("Sources/Views/MixedMediaPage.swift")
        let car = try FetchAnswerTests.squeezedSource("Sources/CarPlay/CarPlaySceneDelegate.swift")
        let shared = try FetchAnswerTests.squeezedSource("Sources/ViewModels/SharedRows.swift")
        #expect(home.contains("SharedRows.listenAgain(albums: recentMusicItems"))
        #expect(page.contains("SharedRows.listenAgain(albums: listenAgainAlbums"))
        #expect(car.contains("LateMusicValues.merged(shelf: await recentAlbums().value ?? [], started: LateMusicValues.shared.recentAlbums)"),
                "the car does not see the playlists Start resolved")
        #expect(car.contains("SharedRows.listenAgain(albums: recent, continued: continued"))
        for text in [home, page] { #expect(!text.contains("RecentlyPlayedRow.merged("), "a surface builds the row a second time") }
        #expect(shared.contains("RecentlyPlayedRow.ownListTimes(") && shared.contains("PlaylistPlaysStore.moments()"))
    }

    @Test("Fence: the playlist tiles of the row carry Remove from Listen Again with the one marker", .needsTheSources)
    func theTilesCarryRemove() throws {
        let home = try FetchAnswerTests.squeezedSource("Sources/Views/HomeView.swift")
        #expect(home.contains("case .ownList(let id):"), "an own list has no tile in the row")
        #expect(home.components(separatedBy: "ListenAgainRemove(").count - 1 >= 2,
                "the own list and the server playlist do not both carry the remove")
        let menu = try FetchAnswerTests.squeezedSource("Sources/Views/Music/MusicView.swift")
        #expect(menu.contains("ListenAgainRemoveButton()"), "the tiles' menu does not offer the remove")
        let remove = try FetchAnswerTests.squeezedSource("Sources/Views/ListenAgainRemove.swift")
        #expect(remove.contains("ContinueHiddenStore.hide(id: tile.id, lastUpdate: tile.momentMs)"), "not the one marker")
    }
}
#endif
