// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// Der Umzug der eigenen Bestaende auf Navidromes neue Kennungen: einmal je
/// Serveradresse, jede Ablage durch ihren eigenen Halter, die Marke erst
/// nach dem letzten Bestand, ein zweiter Lauf schreibt nichts.
@MainActor
struct NavidromeRekeyTests {
    static let old = NavidromeDoorTests.old
    static let new = NavidromeDoorTests.new
    static let map: (String) -> String = { SubsonicProvider.canonicalItemId($0, canonical: true) }

    // MARK: - Die Regel

    @Test("die Regel: Reihenfolge bleibt, alt und neu eines Titels bleiben einmal an der ersten Stelle")
    func theListRule() {
        let ids = ["sub:song:\(Self.old)", "rss:feed:ep", "sub:song:\(Self.new)", "sub:album:a"]
        let rekeyed = NavidromeRekey.rekeyed(ids, Self.map)
        #expect(rekeyed == ["sub:song:\(Self.new)", "rss:feed:ep", "sub:album:a"])
        #expect(NavidromeRekey.rekeyed(rekeyed, Self.map) == rekeyed, "a second pass changes nothing")
        #expect(NavidromeRekey.changedCount(ids, Self.map) == 1)
    }

    @Test("die Regel: Sekunden je Titel addieren sich, die geaenderten Schluessel in fester Folge")
    func theCountAndKeyRules() {
        let counts = ["sub:song:\(Self.old)": 30, "sub:song:\(Self.new)": 12, "rss:feed:ep": 5]
        #expect(NavidromeRekey.summed(counts, Self.map) == ["sub:song:\(Self.new)": 42, "rss:feed:ep": 5])
        let moves = NavidromeRekey.moves(counts.keys, Self.map)
        #expect(moves.map(\.from) == ["sub:song:\(Self.old)"] && moves.map(\.to) == ["sub:song:\(Self.new)"])
        #expect(NavidromeRekey.moves(["sub:song:\(Self.new)"], Self.map).isEmpty)
        #expect(NavidromeRekey.markerKey(server: "music.example/rest") == "navidromeRekeyed.music.example/rest")
    }

    // MARK: - Die Ablagen

    @Test("Warteschlange und Kontext ziehen um, alt und neu bleiben einmal, ein zweiter Lauf schreibt nichts")
    func theQueueAndTheContextMove() {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("rekey-\(UUID().uuidString)")
        let queue = PlayQueue(fileURL: folder.appendingPathComponent("queue.json"), persists: false)
        queue.playLast("sub:song:\(Self.old)")
        queue.playLast("sub:album:a")
        queue.playLast("sub:song:\(Self.new)")
        #expect(queue.ids.count == 3, "the precondition: old and new of one title both queued")
        #expect(queue.rekey(Self.map) == 1)
        #expect(queue.ids == ["sub:song:\(Self.new)", "sub:album:a"])
        #expect(queue.rekey(Self.map) == 0, "a second pass changes nothing")

        let context = PlaybackContext(fileURL: folder.appendingPathComponent("context.json"))
        context.replace(ids: ["sub:song:\(Self.old)", "sub:song:b"], source: "Album")
        #expect(context.rekey(Self.map) == 1)
        #expect(context.ids == ["sub:song:\(Self.new)", "sub:song:b"])
        #expect(context.sourceTitle == "Album", "the title of the rest stays")
        #expect(context.rekey(Self.map) == 0)
    }

    private final class MemoryPending: SyncQueueStorage {
        var stored: [String: SyncQueue.PendingUpdate] = [:]
        var saves = 0
        func load() -> [String: SyncQueue.PendingUpdate] { stored }
        func save(_ pending: [String: SyncQueue.PendingUpdate]) { stored = pending; saves += 1 }
        func awaitPendingWrites() async {}
    }

    @Test("die Sync-Warteschlange zieht um, bei alt und neu bleibt der spaeter eingereihte")
    func thePendingUpdatesMove() async {
        let storage = MemoryPending()
        storage.stored = [
            "sub:album:\(Self.old)": .init(currentTime: 50, duration: 100, isFinished: false, queuedAt: 2_000),
            "sub:album:\(Self.new)": .init(currentTime: 10, duration: 100, isFinished: false, queuedAt: 1_000),
            "rss:feed:ep": .init(currentTime: 5, duration: 60, isFinished: false, queuedAt: 500),
        ]
        let queue = SyncQueue(storage: storage)
        #expect(await queue.rekey(Self.map) == 1)
        #expect(storage.stored["sub:album:\(Self.old)"] == nil)
        #expect(storage.stored["sub:album:\(Self.new)"]?.currentTime == 50, "the one queued later stays")
        #expect(storage.stored["rss:feed:ep"]?.currentTime == 5)
        let saves = storage.saves
        #expect(await queue.rekey(Self.map) == 0)
        #expect(storage.saves == saves, "a second pass writes nothing")
    }

    // MARK: - Die Downloads

    /// An album id as older Navidromes gave it: 32 hex, which the new rule
    /// turns into the same 128 bits in base 62. No exception per kind.
    static let hexAlbum = "0f1e2d3c4b5a69788796a5b4c3d2e1f0"

    static func detail(_ id: String, songs: [String]) -> LibraryItemDetail {
        LibraryItemDetail(
            id: id,
            media: LibraryItemMedia(
                metadata: LibraryItemMetadata(title: "Album", authorName: nil, narratorName: nil,
                                              seriesName: nil, genres: nil, publishedYear: nil, description: nil),
                duration: 300, chapters: nil,
                tracks: songs.enumerated().map { ABSAudioTrack(index: $0.offset, startOffset: nil, duration: 100,
                                                               contentUrl: $0.element, metadata: nil) }),
            userMediaProgress: nil)
    }

    @Test("die Regel: ein Download nennt seine Titel in neuer Form, auch wo das Album bleibt; ein Hoerbuch behaelt seine Spuren")
    func theDownloadDetailRule() {
        let hexAlbum = "sub:album:\(Self.hexAlbum)"
        #expect(Self.map(hexAlbum) != hexAlbum, "the precondition: a hex album id changes too")
        let moved = NavidromeRekey.downloadDetail(Self.detail(hexAlbum, songs: [Self.old, Self.new]),
                                                  id: Self.map(hexAlbum), holder: hexAlbum, Self.map)
        #expect(moved.id == Self.map(hexAlbum))
        #expect(moved.media.tracks?.map(\.contentUrl) == [Self.new, Self.new])
        #expect(moved.media.tracks?.map(\.index) == [0, 1])

        let kept = NavidromeRekey.downloadDetail(Self.detail("sub:album:a", songs: [Self.old]),
                                                 id: "sub:album:a", holder: "sub:album:a", Self.map)
        #expect(kept.media.tracks?.map(\.contentUrl) == [Self.new], "the album id stays, its song ids still change")
        let song = NavidromeRekey.downloadDetail(Self.detail("sub:song:\(Self.old)", songs: [Self.old]),
                                                 id: "sub:song:\(Self.new)", holder: "sub:song:\(Self.old)", Self.map)
        #expect(song.media.tracks?.map(\.contentUrl) == [Self.new])

        let book = Self.detail("li_book", songs: [Self.old])
        #expect(NavidromeRekey.downloadDetail(book, id: "li_book", holder: "li_book", Self.map) == book,
                "a book's track is a path of its server, never a song id")
        let jellyfin = Self.detail("jf:album:x", songs: [Self.old])
        #expect(NavidromeRekey.downloadDetail(jellyfin, id: "jf:album:x", holder: "jf:album:x", Self.map) == jellyfin)
    }

    /// Finished downloads of the builds before: a folder with one file per
    /// track and the document beside it, which the manager pours into rows.
    static func plant(_ items: [(id: String, songs: [String])], in directory: URL) throws {
        let downloads = directory.appendingPathComponent("Downloads", isDirectory: true)
        let meta = directory.appendingPathComponent("DownloadsMeta", isDirectory: true)
        try FileManager.default.createDirectory(at: meta, withIntermediateDirectories: true)
        for (id, songs) in items {
            let folder = downloads.appendingPathComponent(id, isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            for index in songs.indices {
                // An MPEG frame header: the track map takes only what sniffs as audio.
                try Data([0xFF, 0xFB] + [UInt8](repeating: 0, count: 10)).write(to: folder.appendingPathComponent("\(index).mp3"))
            }
            try JSONEncoder().encode(Self.detail(id, songs: songs)).write(to: meta.appendingPathComponent("\(id).json"))
        }
    }

    @Test("ein bleibendes Album findet seine Songs nach dem Umzug im selben Prozess, ohne Neustart")
    func aStayingAlbumFindsItsSongsAtOnce() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("rekey-index-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try Self.plant([("sub:album:a", [Self.old, "b"])], in: directory)
        let manager = DownloadManager(documents: directory,
                                      database: MaerDatabase(path: directory.appendingPathComponent("maer.sqlite").path))
        await manager.ensureScanned()
        #expect(manager.localTrackMap(forItemId: "sub:song:\(Self.old)").count == 1,
                "the precondition: the index was built, and holds the old song id")
        #expect(manager.rekey(Self.map).changed == 1)
        #expect(manager.localTrackMap(forItemId: "sub:song:\(Self.new)").count == 1, "the new id finds its file")
        #expect(manager.loadCachedDetail(forItemId: "sub:song:\(Self.new)") != nil)
        #expect(manager.localTrackMap(forItemId: "sub:song:\(Self.old)").isEmpty)
        #expect(manager.localTrackMap(forItemId: "sub:song:b").count == 1, "a song that kept its id still finds its file")
    }

    @Test("die Downloads ziehen um: Ordner, Zeile und Art unter die neue Kennung, die Titel in neuer Form, ein zweiter Lauf null")
    func theDownloadsMove() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("rekey-downloads-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let downloads = directory.appendingPathComponent("Downloads", isDirectory: true)
        let hexAlbum = "sub:album:\(Self.hexAlbum)"
        let plain = "sub:album:a"
        try Self.plant([(hexAlbum, [Self.old]), (plain, [Self.old, Self.new]), ("li_book", [Self.old])], in: directory)
        try JSONEncoder().encode([hexAlbum: "music"])
            .write(to: directory.appendingPathComponent(DownloadManager.kindsDocument))
        let database = MaerDatabase(path: directory.appendingPathComponent("maer.sqlite").path)
        let manager = DownloadManager(documents: directory, database: database)
        await manager.ensureScanned()
        #expect(manager.downloadedItemIds == [hexAlbum, plain, "li_book"], "the precondition: three downloads")
        #expect(manager.kinds[hexAlbum] == .music, "the precondition: the album has its kind")

        let result = manager.rekey(Self.map)
        #expect(result.changed == 2 && result.total == 3)
        let moved = Self.map(hexAlbum)
        #expect(manager.downloadedItemIds == [moved, plain, "li_book"])
        #expect(FileManager.default.fileExists(atPath: downloads.appendingPathComponent(moved).appendingPathComponent("0.mp3").path))
        #expect(manager.kinds[moved] == .music && manager.kinds[hexAlbum] == nil)
        #expect(manager.loadCachedDetail(forItemId: moved)?.media.tracks?.map(\.contentUrl) == [Self.new])
        #expect(manager.loadCachedDetail(forItemId: plain)?.media.tracks?.map(\.contentUrl) == [Self.new, Self.new])
        #expect(manager.loadCachedDetail(forItemId: "li_book")?.media.tracks?.map(\.contentUrl) == [Self.old])
        #expect(manager.rekey(Self.map).changed == 0, "a second pass changes nothing")

        await manager.awaitPendingWrites()
        let again = DownloadManager(documents: directory, database: database)
        await again.ensureScanned()
        #expect(again.downloadedItemIds == [moved, plain, "li_book"], "the next start finds them under the new ids")
        #expect(again.loadCachedDetail(forItemId: plain)?.media.tracks?.map(\.contentUrl) == [Self.new, Self.new])
    }

    // MARK: - Die Wahlen

    @Test("die Regel: Wahlen kanonisch gelesen, der spaetere Moment gewinnt, bei Gleichstand der neue Schluessel")
    func theChoiceFoldRule() {
        let oldRate = "playbackRate.sub:song:\(Self.old)", newRate = "playbackRate.sub:song:\(Self.new)"
        #expect(NavidromeRekey.choiceKey(oldRate, Self.map) == newRate)
        #expect(NavidromeRekey.choiceKey("podcastSort.feed:x", Self.map) == "podcastSort.feed:x")
        let later = NavidromeRekey.foldedChoices([oldRate: .init(value: .double(1.5), t: 10),
                                                  newRate: .init(value: .double(1.2), t: 5)], Self.map)
        #expect(later == [newRate: .init(value: .double(1.5), t: 10)], "the later statement stands, under the new key")
        let tie = NavidromeRekey.foldedChoices([oldRate: .init(value: .double(1.5), t: 7),
                                                newRate: .init(value: .double(1.2), t: 7)], Self.map)
        #expect(tie[newRate]?.value == .double(1.2), "on an equal moment the one already under the new key")
        let pointer = NavidromeRekey.foldedChoices([AppStorageKeys.lastPlayedItemId:
                                                        .init(value: .string("sub:song:\(Self.old)"), t: 3)], Self.map)
        #expect(pointer[AppStorageKeys.lastPlayedItemId]?.value == .string("sub:song:\(Self.new)"))
        let hidden = NavidromeRekey.foldedChoices([UserChoiceCatalog.hiddenPrefix + "sub:album:\(Self.hexAlbum)":
                                                       .init(value: .double(1), t: 1)], Self.map)
        #expect(hidden.keys.first == UserChoiceCatalog.hiddenPrefix + Self.map("sub:album:\(Self.hexAlbum)"))
    }

    /// A key-value store that counts what is written to it.
    private final class CountingCloud: UserChoiceCloudStore {
        var storage: [String: Any] = [:]
        var writes = 0
        func dictionary(forKey key: String) -> [String: Any]? { storage[key] as? [String: Any] }
        func array(forKey key: String) -> [Any]? { storage[key] as? [Any] }
        func set(_ value: Any?, forKey key: String) { storage[key] = value; writes += 1 }
        func synchronize() -> Bool { true }
        var dictionaryRepresentation: [String: Any] { storage }
        func removeObject(forKey key: String) { storage[key] = nil; writes += 1 }
        var blob: [String: Any] { storage[UserChoiceCloudSync.blobKey] as? [String: Any] ?? [:] }
    }

    private struct Device {
        let sync: UserChoiceCloudSync
        let defaults: UserDefaults
        let suite: String
    }

    private func device(_ cloud: CountingCloud, now: Double, map: @escaping (String) -> String) -> Device {
        let suite = "rekey-choice-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        var clock = now
        let sync = UserChoiceCloudSync(defaults: defaults, cloud: cloud, syncEnabled: { true },
                                       now: { clock += 1; return clock }, itemIdMap: map)
        return Device(sync: sync, defaults: defaults, suite: suite)
    }

    @Test("die eigenen Wahlen ziehen als Mechanik um: mit ihren Stempeln, ohne Notiz, alt und neu einmal, ein zweiter Lauf null")
    func theOwnChoicesMove() {
        let cloud = CountingCloud()
        let here = device(cloud, now: 1000, map: Self.map)
        defer { UserDefaults().removePersistentDomain(forName: here.suite) }
        let d = here.defaults
        let oldRate = "playbackRate.sub:song:\(Self.old)", newRate = "playbackRate.sub:song:\(Self.new)"
        let oldTail = PlayedTail.key("sub:album:\(Self.hexAlbum)")
        let oldHidden = "sub:album:\(Self.hexAlbum)"
        d.set(1.5, forKey: oldRate)
        d.set(1.2, forKey: newRate)
        d.set(30.0, forKey: oldTail)
        d.set([oldHidden: 42.0], forKey: AppStorageKeys.continueHiddenMarkers)
        d.set("sub:song:\(Self.old)", forKey: AppStorageKeys.lastPlayedItemId)
        let clearedOld = "playbackRate.sub:playlist:\(Self.old)"
        d.set([oldRate: 5.0, newRate: 9.0, oldTail: 4.0, clearedOld: 8.0,
               UserChoiceCatalog.hiddenPrefix + oldHidden: 6.0], forKey: UserChoiceCloudSync.stampsKey)

        let first = here.sync.rekeyLocalChoices(Self.map)
        #expect(first.changed == 5)
        #expect(d.object(forKey: oldRate) == nil && d.double(forKey: newRate) == 1.2, "the later statement stays")
        #expect(d.object(forKey: oldTail) == nil
                && d.double(forKey: PlayedTail.key(Self.map("sub:album:\(Self.hexAlbum)"))) == 30)
        #expect(ContinueHiddenStore.markers(defaults: d) == [Self.map(oldHidden): 42])
        #expect(d.string(forKey: AppStorageKeys.lastPlayedItemId) == "sub:song:\(Self.new)")
        let stamps = here.sync.localStamps()
        #expect(stamps[newRate] == 9 && stamps[oldRate] == nil)
        #expect(stamps[PlayedTail.key(Self.map("sub:album:\(Self.hexAlbum)"))] == 4)
        #expect(stamps["playbackRate.sub:playlist:\(Self.new)"] == 8 && stamps[clearedOld] == nil,
                "a clearing moves as a clearing, the old key leaves no tombstone of its own")
        #expect(cloud.writes == 0, "mechanics note nothing")
        #expect(here.sync.rekeyLocalChoices(Self.map).changed == 0, "a second pass changes nothing")
    }

    @Test("Ruhe mit einem alten Geraet: es schreibt den alten Schluessel weiter, das umgezogene uebernimmt einmal und schreibt dann nichts")
    func quietBesideAnOldDevice() {
        let cloud = CountingCloud()
        let moved = device(cloud, now: 1000, map: Self.map)
        let old = device(cloud, now: 2000, map: { $0 })
        defer {
            UserDefaults().removePersistentDomain(forName: moved.suite)
            UserDefaults().removePersistentDomain(forName: old.suite)
        }
        let oldRate = "playbackRate.sub:song:\(Self.old)", newRate = "playbackRate.sub:song:\(Self.new)"
        // Both said a speed for the title under its old key, before the update.
        moved.defaults.set(1.2, forKey: oldRate)
        moved.sync.noteScalar(key: oldRate, value: 1.2)
        old.defaults.set(1.5, forKey: oldRate)
        old.sync.noteScalar(key: oldRate, value: 1.5)

        moved.sync.reconcile()
        #expect(moved.defaults.double(forKey: newRate) == 1.5, "the later statement arrives under the new key")
        #expect(moved.defaults.object(forKey: oldRate) == nil)
        #expect(cloud.blob[oldRate] != nil, "the old key stays in the document")

        for _ in 0..<2 { old.sync.reconcile(); moved.sync.reconcile() }
        let settled = cloud.writes
        for _ in 0..<3 { old.sync.reconcile(); moved.sync.reconcile() }
        #expect(cloud.writes == settled, "after settling nobody writes")

        // The old device goes on under the old key.
        old.defaults.set(1.8, forKey: oldRate)
        old.sync.noteScalar(key: oldRate, value: 1.8)
        let afterNote = cloud.writes
        moved.sync.reconcile()
        #expect(moved.defaults.double(forKey: newRate) == 1.8, "taken over once")
        for _ in 0..<3 { old.sync.reconcile(); moved.sync.reconcile() }
        #expect(cloud.writes == afterNote, "and quiet again")
        #expect(old.defaults.double(forKey: oldRate) == 1.8, "the old device keeps its own")
    }

    /// Over the half of the cap: 300 moved speeds stand in the document
    /// under the old AND the new key, 600 raw keys for 300 statements.
    /// Counted raw, the cap of 500 dropped the oldest pairs whole and the
    /// moved device wrote them back every round. The speeds were said
    /// before the server's update (a device without the new ids); after it
    /// every device runs a build that knows them (all devices are on the
    /// current version). A build from before the rekey
    /// still counts raw, and nothing here can change that.
    @Test("ein Paar alt und neu kostet einen Platz im Deckel: 300 umgezogene Geschwindigkeiten bleiben, danach schreibt niemand")
    func aMovedPairCostsOnePlaceInTheCap() throws {
        let count = 300
        let map: (String) -> String = { id in
            id.hasPrefix("sub:song:old") ? "sub:song:new" + id.dropFirst("sub:song:old".count) : id
        }
        let cloud = CountingCloud()
        let before = device(cloud, now: 1000, map: { $0 })
        let moved = device(cloud, now: 5000, map: map)
        let second = device(cloud, now: 9000, map: map)
        defer {
            for suite in [before.suite, moved.suite, second.suite] {
                UserDefaults().removePersistentDomain(forName: suite)
            }
        }
        try #require(count * 2 > UserChoiceCatalog.playbackRateCap, "the case must cross the cap counted raw")
        for n in 0..<count {
            let key = "playbackRate.sub:song:old\(n)"
            before.defaults.set(1.0 + Double(n % 10) / 10, forKey: key)
            before.sync.noteScalar(key: key, value: 1.0 + Double(n % 10) / 10)
        }
        for _ in 0..<2 { moved.sync.reconcile(); second.sync.reconcile() }
        let rates = cloud.blob.keys.filter { $0.hasPrefix("playbackRate.") }
        #expect(rates.filter { $0.contains(":old") }.count == count, "every old key stays")
        #expect(rates.filter { $0.contains(":new") }.count == count, "every new key stays, none dropped by the cap")
        #expect(moved.defaults.object(forKey: "playbackRate.sub:song:new0") != nil, "the oldest arrived too")
        let arrived = (0..<count).filter { second.defaults.object(forKey: "playbackRate.sub:song:new\($0)") != nil }
        #expect(arrived.count == count, "the second device has every speed")

        let settled = cloud.writes
        for _ in 0..<3 { moved.sync.reconcile(); second.sync.reconcile() }
        #expect(cloud.writes == settled, "after settling nobody writes")

        // The pure count: a pair is one statement, ranked by the newer.
        let drop = UserChoiceMerge.overflowKeys(
            entries: [("playbackRate.sub:song:old1", 10), ("playbackRate.sub:song:new1", 30),
                      ("playbackRate.sub:song:old2", 20)],
            cap: 1, statement: { NavidromeRekey.choiceKey($0, map) })
        #expect(drop == ["playbackRate.sub:song:old2"], "the pair holds the one place, the single key goes")
    }

    // MARK: - Die Mär-Playlisten

    @Test("die Regel: eine Mär-Playlist kanonisch gelesen, alt und neu einmal, ein Entfernen unter dem neuen gilt fuer den alten")
    func thePlaylistRule() {
        let oldId = "sub:song:\(Self.old)", newId = "sub:song:\(Self.new)"
        let entry = MaerPlaylistMerge.Entry(
            name: "Liste", updatedAt: 10, itemIds: [oldId, "rss:f:e", newId],
            titles: [oldId: "alt", newId: "neu"],
            snapshots: [oldId: CarriedItem(id: oldId, title: "alt")],
            added: [oldId: 1, newId: 3, "rss:f:e": 2])
        let read = NavidromeRekey.playlist(entry, Self.map)
        #expect(read.itemIds == [newId, "rss:f:e"])
        #expect(read.titles == [newId: "neu"], "the title already under the new key stays")
        #expect(read.snapshots[newId]?.id == newId, "a carried item names its id inside too")
        #expect(read.added == [newId: 3, "rss:f:e": 2], "the later moment")

        // A device on an older build brings the old form back, while the new
        // form carries a removal made after it was added.
        let back = MaerPlaylistMerge.Entry(name: "Liste", updatedAt: 20, itemIds: [oldId, "rss:f:e"],
                                           removed: [newId: 15], added: [oldId: 1])
        #expect(NavidromeRekey.playlist(back, Self.map).itemIds == ["rss:f:e"], "removed is removed")

        let untouched = MaerPlaylistMerge.Entry(name: "Liste", updatedAt: 5, itemIds: ["rss:f:e"],
                                                titles: ["rss:gone": "a title of an id the list no longer holds"])
        #expect(NavidromeRekey.playlist(untouched, Self.map) == untouched,
                "a list in which no id changes is handed back as it is")
    }

    private final class RecordingPlaylistCarrier: PlaylistCarrier {
        var name: String { "recording" }
        var snapshot = MaerPlaylistMerge.Snapshot()
        var stores = 0
        func held() -> MaerPlaylistMerge.Snapshot { snapshot }
        func store(_ snapshot: MaerPlaylistMerge.Snapshot) {
            self.snapshot = snapshot
            stores += 1
        }
        func start(onChange: @escaping @MainActor () -> Void) {}
        func stop() {}
        func refresh(by caller: String) async {}
    }

    @Test("Ruhe mit einem alten Geraet bei den Mär-Playlisten: kein Schrieb fuer die alte Form, ein Entfernen kommt nicht wieder")
    func playlistsQuietBesideAnOldDevice() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("rekey-playlists-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let was = UserDefaults.standard.object(forKey: AppStorageKeys.podcastICloudSync)
        UserDefaults.standard.set(true, forKey: AppStorageKeys.podcastICloudSync)
        defer {
            if let was { UserDefaults.standard.set(was, forKey: AppStorageKeys.podcastICloudSync) }
            else { UserDefaults.standard.removeObject(forKey: AppStorageKeys.podcastICloudSync) }
        }
        func store(_ name: String) throws -> MaerPlaylists {
            let folder = directory.appendingPathComponent(name, isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            return MaerPlaylists(database: MaerDatabase(path: folder.appendingPathComponent("maer.sqlite").path),
                                 ablage: Ablage(directory: folder))
        }
        let oldId = "sub:song:\(Self.old)", newId = "sub:song:\(Self.new)"
        let carrier = RecordingPlaylistCarrier()
        let oldStore = try store("old"), movedStore = try store("moved")
        let old = MaerPlaylistCloudSync(carrier: carrier, playlists: oldStore, itemIdMap: { $0 })
        let moved = MaerPlaylistCloudSync(carrier: carrier, playlists: movedStore, itemIdMap: Self.map)

        let list = oldStore.create(name: "Unterwegs")
        _ = oldStore.add(itemId: oldId, to: list.id)
        _ = oldStore.add(itemId: "rss:f:e", to: list.id)
        old.reconcile()
        #expect(carrier.snapshot.lists[list.id]?.itemIds == [oldId, "rss:f:e"], "the precondition: the old form travels")

        let before = carrier.stores
        moved.reconcile()
        #expect(movedStore.playlist(id: list.id)?.itemIds == [newId, "rss:f:e"], "read in the new form")
        #expect(carrier.stores == before, "reading the old form in the new one is no change to write")
        for _ in 0..<3 { old.reconcile(); moved.reconcile() }
        #expect(carrier.stores == before, "quiet on both sides")

        // The moved device takes the title out; the old one still holds it
        // under its old id and cannot know the two are one.
        movedStore.remove(itemId: newId, from: list.id)
        moved.reconcile()
        old.reconcile()
        let settled = carrier.stores
        for _ in 0..<3 { old.reconcile(); moved.reconcile() }
        #expect(carrier.stores == settled, "after one answer each, nobody writes")
        #expect(movedStore.playlist(id: list.id)?.itemIds == ["rss:f:e"], "the removal holds on the moved device")
        withExtendedLifetime((old, moved)) {}
    }

    // MARK: - Die Staende

    /// Navidrome's stands travel through the server's bookmarks, which are
    /// read in the new form, never through the stand carrier, which is not.
    /// The move of the ids rests on that: a `sub:` id let into the carrier
    /// would bring the old form back from a device on an older build, and
    /// the moved device would keep it as an orphan beside the new one.
    @Test("der Stand-Traeger traegt keine Navidrome-Kennung, die Staende reisen ueber die Lesezeichen")
    func theStandCarrierCarriesNoNavidromeId() {
        #expect(PodcastCloudSync.potCarries("rss:feed:ep"), "the precondition: the carrier carries stands at all")
        #expect(!PodcastCloudSync.potCarries("sub:song:\(Self.old)"))
        #expect(!PodcastCloudSync.potCarries("sub:album:\(Self.hexAlbum)"))
        #expect(!PodcastCloudSync.potCarries("sub:playlist:\(Self.new)"))
    }

    // MARK: - Der Lauf

    @Test("der Lauf: nur wenn die Regel gilt und die Marke fehlt, die Marke erst nach dem letzten Bestand, einmal")
    func theRunIsOncePerServer() async throws {
        let suite = "rekey-run-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let server = "music.example/rest"
        var ran: [String] = []
        var markerSeenDuringLast = true
        let steps = [
            NavidromeRekeyRun.Step(name: "one") { map in ran.append("one"); return (map("sub:song:\(Self.old)") == "sub:song:\(Self.new)" ? 1 : 0, 1) },
            NavidromeRekeyRun.Step(name: "two") { _ in
                ran.append("two")
                markerSeenDuringLast = defaults.bool(forKey: NavidromeRekey.markerKey(server: server))
                return (0, 0)
            },
        ]
        #expect(!(await NavidromeRekeyRun.runIfDue(by: "witness", server: server, applies: false, defaults: defaults, steps: steps)),
                "without the rule nothing runs")
        #expect(!(await NavidromeRekeyRun.runIfDue(by: "witness", server: nil, applies: true, defaults: defaults, steps: steps)),
                "without a server nothing runs")
        #expect(ran.isEmpty)

        #expect(await NavidromeRekeyRun.runIfDue(by: "witness", server: server, applies: true, defaults: defaults, steps: steps))
        #expect(ran == ["one", "two"])
        #expect(!markerSeenDuringLast, "the marker stood before the last store was done")
        #expect(defaults.bool(forKey: NavidromeRekey.markerKey(server: server)))

        #expect(!(await NavidromeRekeyRun.runIfDue(by: "witness", server: server, applies: true, defaults: defaults, steps: steps)),
                "a second pass for the same server does not run")
        #expect(ran == ["one", "two"])
        #expect(await NavidromeRekeyRun.runIfDue(by: "witness", server: "other.example/rest", applies: true,
                                                 defaults: defaults, steps: steps), "another server address has its own pass")
    }

    /// Which stores the pass names, held in the sources: a store that keeps
    /// `sub:` ids and is left out would keep the old key silently.
    @Test("die Naht: die Schritte des Laufs und der Ausloeser in der Wartung", .needsTheSources)
    func theSeam() throws {
        let run = SyncContractFenceTests.stripped(try String(
            contentsOf: SourceTree.root.appendingPathComponent("Sources/Networking/NavidromeRekeyRun.swift"), encoding: .utf8))
        for name in ["queue", "context", "stands", "stats", "pending", "choices", "playlists", "downloads"] {
            #expect(run.contains("Step(name: \"\(name)\")"), "the pass leaves out \(name)")
        }
        #expect(run.contains("SubsonicProvider.songListRekeyStep,"), "the pass leaves out the kept song list")
        #expect(run.contains("await downloads.ensureScanned()"), "before the scan, no download is known yet")
        let playlists = SyncContractFenceTests.stripped(try String(
            contentsOf: SourceTree.root.appendingPathComponent("Sources/Networking/MaerPlaylistCloudSync.swift"), encoding: .utf8))
        #expect(playlists.contains("playlists.rekey(map)"), "the runner moves its own lists before it reads the carrier")
        #expect(run.contains("defaults.set(true, forKey: marker)"))
        let stats = SyncContractFenceTests.stripped(try String(
            contentsOf: SourceTree.root.appendingPathComponent("Sources/Models/ListeningStats.swift"), encoding: .utf8))
        #expect(stats.contains("ownData.secondsPerItem = NavidromeRekey.summed(ownData.secondsPerItem, map)"))
        let housekeeping = SyncContractFenceTests.stripped(try String(
            contentsOf: SourceTree.root.appendingPathComponent("Sources/ViewModels/AppHousekeeping.swift"), encoding: .utf8))
        #expect(housekeeping.contains("NavidromeRekeyRun.runIfDue(by: \"maintenance\")"))
    }
}
#endif
