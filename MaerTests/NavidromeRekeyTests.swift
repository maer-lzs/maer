// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// The move of the own holdings to Navidrome's new identifiers: once per
/// server address, every store through its own holder, the marker only
/// after the last holding, a second run writes nothing.
@MainActor
struct NavidromeRekeyTests {
    static let old = NavidromeDoorTests.old
    static let new = NavidromeDoorTests.new
    static let map: (String) -> String = { SubsonicProvider.canonicalItemId($0, canonical: true) }

    // MARK: - The rule

    /// Where an old and a new key land on one, one rule decides for every
    /// family: the key already in the new form, else the smaller key.
    @Test("the collision rule exists once: the new key wins, otherwise the smaller", .needsTheSources)
    func theCollisionRuleStandsOnce() throws {
        #expect(NavidromeRekey.prefers("new", over: "old", newKey: "new"))
        #expect(!NavidromeRekey.prefers("old", over: "new", newKey: "new"))
        #expect(NavidromeRekey.prefers("a", over: "b", newKey: "n"), "neither is new: the smaller key")
        #expect(!NavidromeRekey.prefers("b", over: "a", newKey: "n"))
        let code = SyncContractFenceTests.stripped(try String(
            contentsOf: SourceTree.root.appendingPathComponent("Sources/Models/NavidromeRekey.swift"), encoding: .utf8))
        #expect(code.components(separatedBy: "native != heldNative").count - 1 == 1, "the collision rule is written twice")
    }

    /// The stats step of the pass: this device's seconds of a title under
    /// the old and the new key add up under the new one, the store saves,
    /// and a second pass changes nothing. On a database of its own, and its
    /// writes land before the witness ends: on the app's database it read
    /// and wrote the host's rows.
    @Test("the statistics move: old and new of a title add up, a second run changes nothing")
    func theStatsMove() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("rekey-stats-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let stats = ListeningStatsStore(carrier: KeyValueStatsCarrier(store: InMemoryCloudStore()),
                                        database: MaerDatabase(path: directory.appendingPathComponent("maer.sqlite").path),
                                        history: ListeningStatsSyncTests.RecordingHistory())
        let old = "sub:song:\(Self.old)", new = "sub:song:\(Self.new)"
        #expect(stats.ownData.secondsPerItem.isEmpty, "the precondition: a database of its own")
        stats.addSeconds(5, itemId: old)
        stats.addSeconds(7, itemId: new)
        #expect((await stats.rekeyItems(Self.map)?.changed ?? 0) >= 1)
        #expect(stats.ownData.secondsPerItem[old] == nil, "the old key stayed")
        #expect(stats.ownData.secondsPerItem[new] == 12)
        #expect(await stats.rekeyItems(Self.map)?.changed == 0, "a second pass changes nothing")
        await stats.awaitPendingWrites()
    }

    @Test("the rule: order stays, old and new of a title stay once at the first position")
    func theListRule() {
        let ids = ["sub:song:\(Self.old)", "rss:feed:ep", "sub:song:\(Self.new)", "sub:album:a"]
        let rekeyed = NavidromeRekey.rekeyed(ids, Self.map)
        #expect(rekeyed == ["sub:song:\(Self.new)", "rss:feed:ep", "sub:album:a"])
        #expect(NavidromeRekey.rekeyed(rekeyed, Self.map) == rekeyed, "a second pass changes nothing")
        #expect(NavidromeRekey.changedCount(ids, Self.map) == 1)
    }

    @Test("the rule: seconds per title add up, the changed keys in fixed order")
    func theCountAndKeyRules() {
        let counts = ["sub:song:\(Self.old)": 30, "sub:song:\(Self.new)": 12, "rss:feed:ep": 5]
        #expect(NavidromeRekey.summed(counts, Self.map) == ["sub:song:\(Self.new)": 42, "rss:feed:ep": 5])
        let moves = NavidromeRekey.moves(counts.keys, Self.map)
        #expect(moves.map(\.from) == ["sub:song:\(Self.old)"] && moves.map(\.to) == ["sub:song:\(Self.new)"])
        #expect(NavidromeRekey.moves(["sub:song:\(Self.new)"], Self.map).isEmpty)
        #expect(NavidromeRekey.markerKey(server: "music.example/rest") == "navidromeRekeyed.music.example/rest")
    }

    // MARK: - The stores

    @Test("queue and context move, old and new stay once, a second run writes nothing")
    func theQueueAndTheContextMove() {
        let queue = PlayQueue(persists: false)
        queue.playLast("sub:song:\(Self.old)")
        queue.playLast("sub:album:a")
        queue.playLast("sub:song:\(Self.new)")
        #expect(queue.ids.count == 3, "the precondition: old and new of one title both queued")
        #expect(queue.rekey(Self.map) == 1)
        #expect(queue.ids == ["sub:song:\(Self.new)", "sub:album:a"])
        #expect(queue.rekey(Self.map) == 0, "a second pass changes nothing")

        let context = PlaybackContext()
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
        let startReadFailed = false
    }

    @Test("the sync queue moves, of old and new the later queued one stays")
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

    // MARK: - The downloads

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

    @Test("the rule: a download names its titles in the new form, even where the album stays; an audiobook keeps its tracks")
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

    /// Finished downloads: a folder with one file per track and the mark
    /// in the rows of the database beside it.
    static func plant(_ items: [(id: String, songs: [String])], in directory: URL) async throws {
        let downloads = directory.appendingPathComponent("Downloads", isDirectory: true)
        var marks: [String: LibraryItemDetail] = [:]
        for (id, songs) in items {
            let folder = downloads.appendingPathComponent(id, isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            for index in songs.indices {
                // An MPEG frame header: the track map takes only what sniffs as audio.
                try Data([0xFF, 0xFB] + [UInt8](repeating: 0, count: 10)).write(to: folder.appendingPathComponent("\(index).mp3"))
            }
            marks[id] = Self.detail(id, songs: songs)
        }
        let database = MaerDatabase(path: directory.appendingPathComponent("maer.sqlite").path)
        let rows = try await KeyedRowStore<LibraryItemDetail>(connection: try database.connection(), table: .downloadMeta)
        _ = try await rows.replaceAll(marks)
    }

    @Test("a remaining album finds its songs after the move in the same process, without a restart")
    func aStayingAlbumFindsItsSongsAtOnce() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("rekey-index-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try await Self.plant([("sub:album:a", [Self.old, "b"])], in: directory)
        let manager = DownloadManager(documents: directory,
                                      database: MaerDatabase(path: directory.appendingPathComponent("maer.sqlite").path))
        await manager.ensureScanned()
        #expect(manager.localTrackMap(forItemId: "sub:song:\(Self.old)").count == 1,
                "the precondition: the index was built, and holds the old song id")
        #expect(manager.rekey(Self.map)?.changed == 1)
        #expect(manager.localTrackMap(forItemId: "sub:song:\(Self.new)").count == 1, "the new id finds its file")
        #expect(manager.loadCachedDetail(forItemId: "sub:song:\(Self.new)") != nil)
        #expect(manager.localTrackMap(forItemId: "sub:song:\(Self.old)").isEmpty)
        #expect(manager.localTrackMap(forItemId: "sub:song:b").count == 1, "a song that kept its id still finds its file")
    }

    @Test("the downloads move: folder, row and kind under the new identifier, the titles in the new form, a second run zero")
    func theDownloadsMove() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("rekey-downloads-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let downloads = directory.appendingPathComponent("Downloads", isDirectory: true)
        let hexAlbum = "sub:album:\(Self.hexAlbum)"
        let plain = "sub:album:a"
        try await Self.plant([(hexAlbum, [Self.old]), (plain, [Self.old, Self.new]), ("li_book", [Self.old])], in: directory)
        try JSONEncoder().encode([hexAlbum: "music"])
            .write(to: directory.appendingPathComponent(DownloadManager.kindsDocument))
        let database = MaerDatabase(path: directory.appendingPathComponent("maer.sqlite").path)
        let manager = DownloadManager(documents: directory, database: database)
        await manager.ensureScanned()
        #expect(manager.downloadedItemIds == [hexAlbum, plain, "li_book"], "the precondition: three downloads")
        #expect(manager.kinds[hexAlbum] == .music, "the precondition: the album has its kind")

        var heard: [String] = []
        let result = try #require(manager.rekey(Self.map, onMove: { old, new in heard.append("\(old)>\(new)") }))
        #expect(result.changed == 2 && result.total == 3)
        let moved = Self.map(hexAlbum)
        #expect(heard == ["\(hexAlbum)>\(moved)"], "the one download that moved is heard, so its cover can follow")
        #expect(manager.downloadedItemIds == [moved, plain, "li_book"])
        let folder = downloads.appendingPathComponent(DownloadManager.folderName(of: moved))
        #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent("0.mp3").path),
                "a moved folder takes the form of its new id")
        #expect(DownloadManager.itemId(ofFolder: folder) == moved, "and carries the new id")
        #expect(manager.kinds[moved] == .music && manager.kinds[hexAlbum] == nil)
        #expect(manager.loadCachedDetail(forItemId: moved)?.media.tracks?.map(\.contentUrl) == [Self.new])
        #expect(manager.loadCachedDetail(forItemId: plain)?.media.tracks?.map(\.contentUrl) == [Self.new, Self.new])
        #expect(manager.loadCachedDetail(forItemId: "li_book")?.media.tracks?.map(\.contentUrl) == [Self.old])
        #expect(manager.rekey(Self.map, onMove: { old, new in heard.append("\(old)>\(new)") })?.changed == 0,
                "a second pass changes nothing")
        #expect(heard.count == 1, "a second pass moves nothing and hears nothing")

        await manager.awaitPendingWrites()
        let again = DownloadManager(documents: directory, database: database)
        await again.ensureScanned()
        #expect(again.downloadedItemIds == [moved, plain, "li_book"], "the next start finds them under the new ids")
        #expect(again.loadCachedDetail(forItemId: plain)?.media.tracks?.map(\.contentUrl) == [Self.new, Self.new])
    }

    // MARK: - The choices

    @Test("the rule: choices read canonically, the later moment wins, on a tie the new key")
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
                                       now: { clock += 1; return clock }, itemIdMap: map, idFormSettled: { true })
        return Device(sync: sync, defaults: defaults, suite: suite)
    }

    @Test("the own choices move as mechanics: with their stamps, without a note, old and new once, a second run zero")
    func theOwnChoicesMove() throws {
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
        here.sync._seedStampsForWitness([oldRate: 5.0, newRate: 9.0, oldTail: 4.0, clearedOld: 8.0,
                                         UserChoiceCatalog.hiddenPrefix + oldHidden: 6.0])

        let first = try #require(here.sync.rekeyLocalChoices(Self.map), "the precondition: the stamps are read")
        #expect(first.changed == 5)
        #expect(d.object(forKey: oldRate) == nil && d.double(forKey: newRate) == 1.2, "the later statement stays")
        #expect(d.object(forKey: oldTail) == nil
                && d.double(forKey: PlayedTail.key(Self.map("sub:album:\(Self.hexAlbum)"))) == 30)
        #expect(ContinueHiddenStore.markers(defaults: d) == [Self.map(oldHidden): 42])
        #expect(d.string(forKey: AppStorageKeys.lastPlayedItemId) == "sub:song:\(Self.new)")
        let stamps = try #require(here.sync.localStamps())
        #expect(stamps[newRate] == 9 && stamps[oldRate] == nil)
        #expect(stamps[PlayedTail.key(Self.map("sub:album:\(Self.hexAlbum)"))] == 4)
        #expect(stamps["playbackRate.sub:playlist:\(Self.new)"] == 8 && stamps[clearedOld] == nil,
                "a clearing moves as a clearing, the old key leaves no tombstone of its own")
        #expect(cloud.writes == 0, "mechanics note nothing")
        #expect(here.sync.rekeyLocalChoices(Self.map)?.changed == 0, "a second pass changes nothing")
    }

    @Test("calm with an old device: it keeps writing the old key, the moved one adopts once and then writes nothing")
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
    @Test("a pair of old and new costs one place in the cap: 300 moved speeds stay, after that nobody writes")
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

    // MARK: - The Mär playlists

    @Test("the rule: a Mär playlist read canonically, old and new once, a removal under the new one applies to the old one")
    func thePlaylistRule() {
        let oldId = "sub:song:\(Self.old)", newId = "sub:song:\(Self.new)"
        let entry = MaerPlaylistMerge.Entry(
            name: "Liste", updatedAt: 10, itemIds: [oldId, "rss:f:e", newId],
            titles: [oldId: "alt", newId: "neu"],
            snapshots: [oldId: CarriedItem(id: oldId, title: "alt")],
            added: [oldId: 1, newId: 3, "rss:f:e": 2])
        let read = NavidromeRekey.playlist(entry, list: "liste", Self.map)
        #expect(read.itemIds == [newId, "rss:f:e"])
        #expect(read.titles == [newId: "neu"], "the title already under the new key stays")
        #expect(read.snapshots[newId]?.id == newId, "a carried item names its id inside too")
        #expect(read.added == [newId: 3, "rss:f:e": 2], "the later moment")

        // A device on an older build brings the old form back, while the new
        // form carries a removal made after it was added.
        let back = MaerPlaylistMerge.Entry(name: "Liste", updatedAt: 20, itemIds: [oldId, "rss:f:e"],
                                           removed: [newId: 15], added: [oldId: 1])
        #expect(NavidromeRekey.playlist(back, list: "liste", Self.map).itemIds == ["rss:f:e"], "removed is removed")

        let untouched = MaerPlaylistMerge.Entry(name: "Liste", updatedAt: 5, itemIds: ["rss:f:e"],
                                                titles: ["rss:gone": "a title of an id the list no longer holds"])
        #expect(MaerPlaylistMerge.isSameVersion(NavidromeRekey.playlist(untouched, list: "liste", Self.map), untouched),
                "a list in which no id changes is handed back as it is")
    }

    /// The line a dropped rule writes names its list: the merge takes the
    /// list's id without a default, and the move hands it on.
    @Test("the row of a dropped rule names its list, also when rekeying", .needsTheSources)
    func theMergeLineNamesItsList() throws {
        let merge = try FetchAnswerTests.squeezedSource("Sources/Models/MaerPlaylistMerge.swift")
        #expect(merge.contains("static func unite(_ a: Entry, _ b: Entry, list: String) -> Entry {"),
                "the list's id has a default again, a caller may leave it out")
        let rekey = try FetchAnswerTests.squeezedSource("Sources/Models/NavidromeRekey.swift")
        #expect(rekey.contains("return MaerPlaylistMerge.unite(mapped, mapped, list: list)"))
        #expect(rekey.contains("(id, playlist(entry, list: id, map))"), "the snapshot's lists pass on their ids")
        let lists = try FetchAnswerTests.squeezedSource("Sources/Providers/MaerPlaylists.swift")
        #expect(lists.contains("NavidromeRekey.playlist(Self.entry(of: list), list: list.id, map)"))
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

    @Test("calm with an old device for the Mär playlists: no write for the old form, a removal does not come back")
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
            return MaerPlaylists(database: MaerDatabase(path: folder.appendingPathComponent("maer.sqlite").path))
        }
        let oldId = "sub:song:\(Self.old)", newId = "sub:song:\(Self.new)"
        let carrier = RecordingPlaylistCarrier()
        let oldStore = try store("old"), movedStore = try store("moved")
        let old = MaerPlaylistCloudSync(carrier: carrier, playlists: oldStore, itemIdMap: { $0 }, idFormSettled: { true })
        let moved = MaerPlaylistCloudSync(carrier: carrier, playlists: movedStore, itemIdMap: Self.map, idFormSettled: { true })

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

    // MARK: - The listening positions

    /// Navidrome's stands travel through the server's bookmarks, which are
    /// read in the new form, never through the stand carrier, which is not.
    /// The move of the ids rests on that: a `sub:` id let into the carrier
    /// would bring the old form back from a device on an older build, and
    /// the moved device would keep it as an orphan beside the new one.
    @Test("the position carrier carries no Navidrome identifier, the positions travel through the bookmarks")
    func theStandCarrierCarriesNoNavidromeId() {
        #expect(PodcastCloudSync.potCarries("rss:feed:ep"), "the precondition: the carrier carries stands at all")
        #expect(!PodcastCloudSync.potCarries("sub:song:\(Self.old)"))
        #expect(!PodcastCloudSync.potCarries("sub:album:\(Self.hexAlbum)"))
        #expect(!PodcastCloudSync.potCarries("sub:playlist:\(Self.new)"))
    }

    // MARK: - The run

    @Test("the run: only when the rule applies and the marker is missing, the marker only after the last holding, once")
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

    /// A step that cannot do its work now (a kept song list that stayed on
    /// the disk) keeps the pass open: no marker, and the next occasion runs
    /// it again.
    @Test("a step that cannot keeps the run open; the next run sets the marker")
    func aStepThatCannotKeepsThePassOpen() async throws {
        let suite = "rekey-open-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let server = "music.example/rest"
        final class Switch { var possible = false }
        let state = Switch()
        let steps = [
            NavidromeRekeyRun.Step(name: "kept") { _ in state.possible ? (0, 1) : nil },
            NavidromeRekeyRun.Step(name: "other") { _ in (1, 1) },
        ]
        #expect(await NavidromeRekeyRun.runIfDue(by: "witness", server: server, applies: true, defaults: defaults, steps: steps))
        #expect(!defaults.bool(forKey: NavidromeRekey.markerKey(server: server)), "the marker stands although a step could not")
        state.possible = true
        #expect(await NavidromeRekeyRun.runIfDue(by: "witness", server: server, applies: true, defaults: defaults, steps: steps),
                "the pass runs again")
        #expect(defaults.bool(forKey: NavidromeRekey.markerKey(server: server)))
    }

    /// "Not now" keeps the pass open; "not possible here" is skipped with
    /// its reason and the marker may come, or the pass would run for ever.
    @Test("not now keeps the run open, not possible here is skipped with a reason and the marker comes")
    func notHereIsSkippedNotNowWaits() async throws {
        let suite = "rekey-here-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let server = "music.example/rest"
        var ran: [String] = []
        let steps = [
            NavidromeRekeyRun.Step(name: "never here", outcome: { _ in ran.append("never here"); return .notHere(reason: "witness") }),
            NavidromeRekeyRun.Step(name: "other") { _ in ran.append("other"); return (1, 1) },
        ]
        #expect(await NavidromeRekeyRun.runIfDue(by: "witness", server: server, applies: true, defaults: defaults, steps: steps))
        #expect(ran == ["never here", "other"], "a step after the skipped one did not run")
        #expect(defaults.bool(forKey: NavidromeRekey.markerKey(server: server)), "a step not possible here kept the pass open")
    }

    /// Rows that do not decode in this build do not decode at a later start
    /// either: the move does not wait for them, it names them, and they
    /// keep their old ids.
    @Test("a holding with undecoded rows does not hold up the move; the step's row names them")
    func rowsNotReadDoNotHoldThePass() async throws {
        let suite = "rekey-missed-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let server = "music.example/rest"
        let steps = [NavidromeRekeyRun.Step(name: "missed", missedRows: { true }) { _ in (1, 2) }]
        #expect(await NavidromeRekeyRun.runIfDue(by: "witness", server: server, applies: true, defaults: defaults, steps: steps))
        #expect(defaults.bool(forKey: NavidromeRekey.markerKey(server: server)), "rows not read held the pass open")
        #expect(NavidromeRekeyRun.doneLine("missed", changed: 1, total: 2, missedRows: true, by: "w")
                == "REKEY missed rewritten=1 unchanged=1 by=w; rows not read at start keep their old ids")
        #expect(NavidromeRekeyRun.doneLine("whole", changed: 1, total: 2, missedRows: false, by: "w")
                == "REKEY whole rewritten=1 unchanged=1 by=w")
        // A store's answer comes from its chain: a playlist row that does
        // not decode makes the start incomplete.
        let folder = try Self.temporaryDirectory("rekey-missed-rows")
        defer { try? FileManager.default.removeItem(at: folder) }
        let database = MaerDatabase(path: folder.appendingPathComponent("maer.sqlite").path)
        _ = try await KeyedRowStore<MaerPlaylists.Playlist>(connection: try database.connection(), table: .maerPlaylist)
        _ = try await database.connection().run("INSERT INTO maer_playlist (key, payload) VALUES (?, ?)",
                                                [.text("later-form"), .blob(Data("not a list".utf8))])
        #expect(MaerPlaylists(database: database).startIncomplete, "a row that did not decode left the start complete")
    }

    /// The kept song list: no address is "not possible here" (nothing on
    /// this device to drop), a list that stayed on the disk is "not now".
    @Test("the song list: without an address not possible here, a remaining list not now, a removed one done")
    func theSongListAnswersBothWays() async throws {
        let provider = SubsonicProvider.shared
        let none = await provider.forgetSongCatalog(at: nil, removing: { _ in Issue.record("removed without an address") })
        #expect(none == .noAddress)
        #expect(SubsonicProvider.songListOutcome(none) == .notHere(reason: "no server address"))
        let address = try #require(URL(string: "https://songlist-witness-\(UUID().uuidString.prefix(6)).example/rest"))
        let stayed = await provider.forgetSongCatalog(at: address, removing: { _ in throw CocoaError(.fileWriteNoPermission) })
        #expect(stayed == .stayed)
        #expect(SubsonicProvider.songListOutcome(stayed) == .notNow)
        let gone = await provider.forgetSongCatalog(at: address, removing: { _ in })
        #expect(gone == .dropped(held: false))
        #expect(SubsonicProvider.songListOutcome(gone) == .done(changed: 0, total: 1))
    }

    /// One reading of the typed address: a setting the client cannot take
    /// gives no server key and no list address either.
    @Test("one reading of the server address: what the client does not accept also gives no server key and no list address")
    func oneReadingOfTheServerAddress() {
        let previous = AppStorageKeys.subsonicServerURLValue
        defer { AppStorageKeys.subsonicServerURLValue = previous }
        for setting in ["//music.example/rest", "music.example/rest", "  "] {
            AppStorageKeys.subsonicServerURLValue = setting
            #expect(SubsonicClient(serverURL: setting, username: "hoerer", password: "geheim-42") == nil)
            #expect(SubsonicProvider.serverAddress(setting) == nil)
            #expect(SubsonicProvider.configuredServerKey == nil, "a key without a client for \(setting)")
        }
        let setting = " https://music.example/rest "
        AppStorageKeys.subsonicServerURLValue = setting
        let client = SubsonicClient(serverURL: setting, username: "hoerer", password: "geheim-42")
        #expect(client?.baseURL == SubsonicProvider.serverAddress(setting))
        #expect(SubsonicProvider.configuredServerKey == "music.example/rest")
    }

    /// Music off here at the update: the cover addresses need the client, so
    /// a download that would move keeps the pass open instead of moving
    /// without its cover. Then music on: the download moves, the cover
    /// follows and stands kept under the new form.
    @Test("without a music client a download that would have to move keeps the run open; with a client it moves and the cover follows")
    func theDownloadsStepWaitsForTheCovers() async throws {
        let suite = "rekey-covers-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let server = "music.example/rest"
        let marker = NavidromeRekey.markerKey(server: server)
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("rekey-covers-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let album = "sub:album:\(Self.hexAlbum)"
        let moved = Self.map(album)
        try await Self.plant([(album, [Self.old])], in: directory)
        let manager = DownloadManager(documents: directory,
                                      database: MaerDatabase(path: directory.appendingPathComponent("maer.sqlite").path))
        // A kept cover under the old form, renamed the way the pass renames it.
        let cover: (String) -> URL = { URL(string: "https://nd.example.lan/rest/getCoverArt.view?id=\($0)-\(suite)&size=600")! }
        // The tiers move files by name; the bytes are never read here.
        #expect(ImageCache.shared.testPlacePersistent(Data("cover".utf8), for: cover(album)), "the precondition: a kept cover")
        defer { ImageCache.shared.removePersistent(coverURL: cover(album)); ImageCache.shared.removePersistent(coverURL: cover(moved)) }
        final class Music { var on = false; var renamed: [String] = [] }
        let music = Music()
        let step = NavidromeRekeyRun.downloadsStep(manager: { manager }, canRename: { music.on }, rename: { old, new in
            music.renamed.append("\(old)>\(new)")
            ImageCache.shared.renamePersistent(from: cover(old), to: cover(new))
        })

        #expect(await NavidromeRekeyRun.runIfDue(by: "witness", server: server, applies: true, defaults: defaults, steps: [step]))
        #expect(!defaults.bool(forKey: marker), "music off: the pass stays open")
        #expect(NavidromeRekeyRun.isPending(server: server, applies: true, defaults: defaults), "so the cover sweep holds")
        #expect(manager.downloadedItemIds == [album] && music.renamed.isEmpty, "nothing moved without its cover")
        #expect(ImageCache.shared.testIsPersistent(cover(album)))

        music.on = true
        #expect(await NavidromeRekeyRun.runIfDue(by: "witness", server: server, applies: true, defaults: defaults, steps: [step]))
        #expect(music.renamed == ["\(album)>\(moved)"])
        #expect(manager.downloadedItemIds == [moved])
        #expect(defaults.bool(forKey: marker), "the pass is done once the covers could follow")
        // The rename moves the file in the disk chain of the address.
        await ImageCache.shared.testDiskSettled(cover(moved))
        #expect(ImageCache.shared.testIsPersistent(cover(moved)) && !ImageCache.shared.testIsPersistent(cover(album)),
                "the cover stands kept under the new form")

        // A device whose downloads do not move does not wait for music.
        let books = directory.appendingPathComponent("books", isDirectory: true)
        try await Self.plant([("li_book", [Self.old])], in: books)
        let bookManager = DownloadManager(documents: books,
                                          database: MaerDatabase(path: books.appendingPathComponent("maer.sqlite").path))
        let bookStep = NavidromeRekeyRun.downloadsStep(manager: { bookManager }, canRename: { false }, rename: { _, _ in })
        #expect(await NavidromeRekeyRun.runIfDue(by: "witness", server: "books.example/rest", applies: true,
                                                 defaults: defaults, steps: [bookStep]))
        #expect(defaults.bool(forKey: NavidromeRekey.markerKey(server: "books.example/rest")),
                "nothing would move, so the pass completes without the client")
    }

    /// A rename only queues its move. The marker waits for it: while the
    /// move of the cover is held in the disk chain the pass stays pending,
    /// a sweep right then demotes nothing, and once the move lands the
    /// marker falls and the cover stands kept under the new form.
    @Test("the marker of the move falls only when the queued renaming of the cover has landed")
    func theMarkerWaitsForTheQueuedRename() async throws {
        let suite = "rekey-settle-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let server = "music.example/rest"
        let marker = NavidromeRekey.markerKey(server: server)
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("rekey-settle-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let album = "sub:album:\(Self.hexAlbum)"
        let moved = Self.map(album)
        try await Self.plant([(album, [Self.old])], in: directory)
        let manager = DownloadManager(documents: directory,
                                      database: MaerDatabase(path: directory.appendingPathComponent("maer.sqlite").path))
        let cover: (String) -> URL = { URL(string: "https://nd.example.lan/rest/getCoverArt.view?id=\($0)-\(suite)&size=600")! }
        #expect(ImageCache.shared.testPlacePersistent(Data("cover".utf8), for: cover(album)), "the precondition: a kept cover")
        defer { ImageCache.shared.removePersistent(coverURL: cover(album)); ImageCache.shared.removePersistent(coverURL: cover(moved)) }
        final class Renames { var queued = 0 }
        let renames = Renames()
        let step = NavidromeRekeyRun.downloadsStep(manager: { manager }, canRename: { true }, rename: { old, new in
            ImageCache.shared.renamePersistent(from: cover(old), to: cover(new))
            renames.queued += 1
        })

        let release = ImageCache.shared.testHoldDisk(cover(album))
        let pass = Task { await NavidromeRekeyRun.runIfDue(by: "witness", server: server, applies: true,
                                                          defaults: defaults, steps: [step]) }
        for _ in 0..<200 where renames.queued == 0 || !defaults.bool(forKey: marker) { await Task.yield() }
        #expect(renames.queued == 1, "the precondition: the rename is queued")
        #expect(!defaults.bool(forKey: marker), "the marker fell before the queued rename landed")
        #expect(ImageCache.shared.testIsPersistent(cover(album)), "the precondition: the move is still held")

        // A sweep right then, as the housekeeping starts one next to the pass.
        let pending = { NavidromeRekeyRun.isPending(server: server, applies: true, defaults: defaults) }
        let covers = await manager.activeCovers(address: { cover($0) }, largeAddress: { _ in nil }, idMovePending: pending)
        #expect(!covers.knowsAll, "while the rename is queued the sweep cannot name every cover")
        await ImageCache.shared.performMaintenance(activeCoverURLs: covers.urls, knowsAll: covers.knowsAll).value

        release()
        #expect(await pass.value)
        #expect(defaults.bool(forKey: marker), "the pass is done once the rename landed")
        #expect(ImageCache.shared.testIsPersistent(cover(moved)) && !ImageCache.shared.testIsPersistent(cover(album)),
                "the cover stands kept under the new form")
    }

    /// The kept song list is named by the address the client reads, so the
    /// pass finds it by the stored address while music is off here.
    @Test("the song list is named after the address, with a client as without")
    func theSongListIsNamedByTheAddress() throws {
        let setting = "  https://music.example.test/navidrome "
        let client = try #require(SubsonicClient(serverURL: setting, username: "u", password: "p"))
        let address = try #require(SubsonicProvider.serverAddress(setting))
        #expect(SubsonicProvider.songCatalogName(forAddress: address) == SubsonicProvider.songCatalogName(for: client),
                "without a client the pass looks for another file than the client wrote")
        #expect(SubsonicProvider.serverAddress("music") == nil, "an address without a scheme names no list")
    }

    /// An interrupted download (a folder without a mark, kept for resume)
    /// moves with the pass, so a resume under the new id finds its parts;
    /// one whose new folder is already there stays.
    @Test("an aborted download moves along, an occupied target stays")
    func anInterruptedDownloadMovesToo() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("rekey-remnant-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let downloads = directory.appendingPathComponent("Downloads", isDirectory: true)
        let old = "sub:album:\(Self.hexAlbum)"
        let taken = "sub:playlist:\(Self.old)"
        for id in [old, taken, Self.map(taken)] {
            let folder = downloads.appendingPathComponent(id, isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data([0xFF, 0xFB] + [UInt8](repeating: 0, count: 10)).write(to: folder.appendingPathComponent("0.mp3"))
        }
        let manager = DownloadManager(documents: directory,
                                      database: MaerDatabase(path: directory.appendingPathComponent("maer.sqlite").path))
        await manager.ensureScanned()
        #expect(manager.downloadedItemIds.isEmpty, "the precondition: no folder carries a mark")
        let measured = manager.sizeMeasurements

        let result = try #require(manager.rekey(Self.map))
        #expect(manager.sizeMeasurements == measured, "a pass that moved only interrupted downloads measured the sizes")
        let moved = downloads.appendingPathComponent(DownloadManager.folderName(of: Self.map(old)))
            .appendingPathComponent("0.mp3").path
        #expect(FileManager.default.fileExists(atPath: moved), "the interrupted download stayed under its old id")
        #expect(!FileManager.default.fileExists(atPath: downloads.appendingPathComponent(old).path))
        #expect(FileManager.default.fileExists(atPath: downloads.appendingPathComponent(taken).path), "a taken target is left alone")
        #expect(result.changed == 1)
        #expect(manager.rekey(Self.map)?.changed == 0, "a second pass changes nothing")
    }

    /// A folder of downloads that exists but cannot be listed is "not now",
    /// with a line: no answer is no "no interrupted download". A missing
    /// folder holds none.
    @Test("an unreadable download folder keeps the step open, a missing one is empty",
          .enabled(if: NavidromeRekeyTests.aShutFolderStaysShut, "a shut folder can be listed here, so there is nothing to measure"))
    func anUnreadableDownloadsFolderIsNotNow() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("rekey-unreadable-\(UUID().uuidString)", isDirectory: true)
        let downloads = directory.appendingPathComponent("Downloads", isDirectory: true)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: downloads.path)
            try? FileManager.default.removeItem(at: directory)
        }
        try FileManager.default.createDirectory(at: downloads.appendingPathComponent("sub:album:\(Self.hexAlbum)"),
                                                withIntermediateDirectories: true)
        let manager = DownloadManager(documents: directory,
                                      database: MaerDatabase(path: directory.appendingPathComponent("maer.sqlite").path))
        await manager.ensureScanned()
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: downloads.path)
        #expect(manager.rekey(Self.map) == nil, "an unreadable folder read as no interrupted download")
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: downloads.path)
        try FileManager.default.removeItem(at: downloads)
        #expect(manager.rekey(Self.map) != nil, "a missing folder held the step")
    }

    /// Whether a folder shut to everyone cannot be listed where the suite
    /// runs. Run with the rights to read anyway, the unreadable folder
    /// cannot be made, and the case is skipped, not passed.
    nonisolated static var aShutFolderStaysShut: Bool {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("shut-probe-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path)
            try? FileManager.default.removeItem(at: folder)
        }
        guard (try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)) != nil,
              (try? FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: folder.path)) != nil
        else { return false }
        return (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) == nil
    }

    /// A folder held for a resume neither moves nor is cleared: a resume
    /// clears the phase before its download runs, the control stands
    /// throughout. Both ways ask the one question.
    @Test("the guard of the aborted downloads asks the control as well", .needsTheSources)
    func theRemnantGuardAsksTheControls() throws {
        let code = SyncContractFenceTests.stripped(try String(
            contentsOf: SourceTree.root.appendingPathComponent("Sources/Networking/DownloadManager.swift"), encoding: .utf8))
        func body(_ head: String, _ length: Int) throws -> String {
            try #require(code.range(of: head).map { String(code[$0.upperBound...].prefix(length)) })
        }
        let holds = try body("private func downloadHolds(", 200)
        let rekey = try body("private func rekeyRemnants(", 1800)
        let clear = try body("private func clearOldRemnants(", 1200)
        #expect(holds.contains("phase[itemId] != nil || controls[itemId] != nil"), "the question leaves the control out")
        #expect(rekey.contains("!downloadHolds(oldId)"), "a folder held for a resume can move")
        #expect(clear.contains("active: downloadHolds(itemId)"), "a folder held for a resume can be cleared")
    }

    /// A pass over many downloads writes the marks and the kinds and
    /// measures the sizes once, not per download; a delete of many as well.
    @Test("the move and the deletion of many write and measure once", .needsTheSources)
    func manyMovesWriteAndMeasureOnce() throws {
        let code = SyncContractFenceTests.stripped(try String(
            contentsOf: SourceTree.root.appendingPathComponent("Sources/Networking/DownloadManager.swift"), encoding: .utf8))
        for head in ["func rekey(_ map: (String) -> String,", "func deleteDownloads(_ itemIds: Set<String>)"] {
            let start = try #require(code.range(of: head), "\(head) is gone")
            let rest = code[start.upperBound...]
            let end = rest.range(of: "\n    }\n")?.lowerBound ?? rest.endIndex
            let body = rest[..<end]
            #expect(body.components(separatedBy: "recalculateTotalSize()").count - 1 == 1, "\(head): sizes measured per item")
            #expect(body.components(separatedBy: "writeKinds()").count - 1 == 1, "\(head): kinds written per item")
            #expect(body.components(separatedBy: "keeper.write(").count - 1 == 1, "\(head): marks written per item")
            #expect(!body.contains("adoptDownload("), "\(head): goes through the move with its writes")
        }
    }

    // MARK: - Unread stores

    /// A database file whose named tables carry no `key` and `payload`
    /// columns: the start read of each fails as a whole, as a read error
    /// does, and the file holds a row, so it is no fresh install.
    static func unreadableDatabase(_ tables: [String], at path: String) async throws -> MaerDatabase {
        let database = MaerDatabase(path: path)
        let connection = try database.connection()
        for table in tables { try await connection.execute("CREATE TABLE \(table) (other TEXT)") }
        try await connection.execute("INSERT INTO \(tables[0]) (other) VALUES ('x')")
        _ = try await connection.checkpoint()
        return database
    }

    static func temporaryDirectory(_ name: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    /// A store whose start could not read its rows holds in memory only what
    /// this run added; the rows may hold old ids. The step answers nil, so
    /// the marker stays off and a later start that reads moves them.
    @Test("a store whose start read failed does not move: queue, context, sync queue, playlists, downloads answer nil")
    func aStoreWhoseStartReadFailedDoesNotMove() async throws {
        let directory = try Self.temporaryDirectory("rekey-unread")
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = try await Self.unreadableDatabase(
            ["play_queue", "playback_context", "pending_sync", "maer_playlist", "download_meta"],
            at: directory.appendingPathComponent("maer.sqlite").path)
        #expect(try database.readerNow() != nil, "the precondition: the file is no fresh install")
        let old = "sub:song:\(Self.old)"

        let queue = PlayQueue(persists: true, database: database)
        queue.playLast(old)
        #expect(queue.rekey(Self.map) == nil, "the queue moved over a row it never read")
        #expect(queue.ids == [old])

        let context = PlaybackContext(persists: true, database: database)
        context.replace(ids: [old], source: "Album")
        #expect(context.rekey(Self.map) == nil, "the context moved over a row it never read")

        let pending = SyncQueue(storage: SyncQueueRowStorage(database: database))
        #expect(await pending.rekey(Self.map) == nil, "the sync queue moved over rows it never read")

        #expect(MaerPlaylists(database: database).rekey(Self.map) == nil, "the lists moved over rows they never read")

        let downloads = DownloadManager(documents: directory, database: database)
        await downloads.ensureScanned()
        #expect(downloads.rekey(Self.map) == nil, "the downloads moved over marks they never read")

        // The same stores over a file they can read move what they hold.
        let readable = MaerDatabase(path: directory.appendingPathComponent("readable.sqlite").path)
        let readQueue = PlayQueue(persists: true, database: readable)
        readQueue.playLast(old)
        #expect(readQueue.rekey(Self.map) == 1, "the control: a queue that read its row moves")
        let readPending = SyncQueue(storage: SyncQueueRowStorage(database: readable))
        #expect(await readPending.rekey(Self.map) == 0, "the control: a sync queue that read its rows answers")
        let readContext = PlaybackContext(persists: true, database: readable)
        readContext.replace(ids: [old], source: "Album")
        #expect(readContext.rekey(Self.map) == 1, "the control: a context that read its row moves")
        #expect(MaerPlaylists(database: readable).rekey(Self.map) != nil, "the control: lists that read their rows answer")
        let readDocuments = directory.appendingPathComponent("readable", isDirectory: true)
        let readDownloads = DownloadManager(documents: readDocuments, database: readable)
        await readDownloads.ensureScanned()
        #expect(readDownloads.rekey(Self.map) != nil, "the control: downloads that read their marks answer")
        // The chains end before the files go.
        await queue.awaitPendingWrites()
        await context.awaitPendingWrites()
        await readQueue.awaitPendingWrites()
        await readContext.awaitPendingWrites()
        await RowKeepers.awaitAll()
    }

    @Test("the listening positions do not move while reading their table failed; once read they move")
    func theStandsWaitForTheirTable() throws {
        let suite = "rekey-stands-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: ListeningStore.movedKey)
        struct ReadFailed: Error {}
        ListeningStore.installTable(for: defaults) { throw ReadFailed() }
        #expect(ListeningStore.rekey(Self.map, in: defaults) == nil, "the stands moved over a table nobody read")

        let old = "sub:song:\(Self.old)", new = "sub:song:\(Self.new)"
        let stock = ListeningStore.Stock(backups: [old: [12, 1_700_000_000]], flushed: [:])
        ListeningStore.installTable(for: defaults) { stock }
        let moved = try #require(ListeningStore.rekey(Self.map, in: defaults))
        #expect(moved.changed == 1 && moved.total == 1)
        #expect(ListeningStore.positions(in: defaults)[new] == [12, 1_700_000_000])
        #expect(ListeningStore.positions(in: defaults)[old] == nil)
    }

    /// The table the start could not read is read before the move, so its
    /// rows move with the run's; while it stays unread the step answers nil.
    @Test("the statistics read an unread table again before the move; if it stays unread, the step answers nil")
    func theStatsReadBeforeTheyMove() async throws {
        let directory = try Self.temporaryDirectory("rekey-stats")
        defer { try? FileManager.default.removeItem(at: directory) }
        let old = "sub:song:\(Self.old)", new = "sub:song:\(Self.new)"
        let carrier = KeyValueStatsCarrier(store: InMemoryCloudStore())

        let broken = try await Self.unreadableDatabase(["stats_item"], at: directory.appendingPathComponent("broken.sqlite").path)
        let blind = ListeningStatsStore(carrier: carrier, database: broken, history: ListeningStatsSyncTests.RecordingHistory())
        blind.addSeconds(5, itemId: old)
        #expect(await blind.rekeyItems(Self.map) == nil, "the stats moved over a table nobody could read")

        let database = MaerDatabase(path: directory.appendingPathComponent("maer.sqlite").path)
        _ = try await KeyedRowStore<Int>(connection: try database.connection(), table: .statsDay)
        let items = try await KeyedRowStore<Int>(connection: try database.connection(), table: .statsItem)
        _ = try await items.apply(previous: [:], current: [old: 2400])
        let stats = ListeningStatsStore.testFailingStart(carrier: carrier, database: database,
                                                         history: ListeningStatsSyncTests.RecordingHistory())
        #expect(stats.seconds(forItemId: old) == 0, "the precondition: the start read no row")
        let moved = try #require(await stats.rekeyItems(Self.map))
        #expect(moved.changed == 1)
        await stats.awaitPendingWrites()
        let reader = try #require(try database.readerNow())
        let rows = try KeyedRowStore<Int>.loadNow(table: .statsItem, reader: reader).rows
        #expect(rows[new] == 2400, "the row read on the move is not under the new id: \(rows)")
        #expect(rows[old] == nil, "the old id stayed in the rows")
    }

    /// Each table on its own: a table the start read is not read again.
    /// Here the day table turns unreadable after the start and the item
    /// table readable; the read again asks only the item table and goes.
    @Test("the statistics re-read only the unread table; one read at start does not hold them up")
    func theStatsReadOnlyTheUnreadTable() async throws {
        let directory = try Self.temporaryDirectory("rekey-stats-table")
        defer { try? FileManager.default.removeItem(at: directory) }
        let old = "sub:song:\(Self.old)", new = "sub:song:\(Self.new)"
        let database = MaerDatabase(path: directory.appendingPathComponent("maer.sqlite").path)
        let days = try await KeyedRowStore<Int>(connection: try database.connection(), table: .statsDay)
        _ = try await days.apply(previous: [:], current: ["2026-10-04": 300])
        let connection = try database.connection()
        try await connection.execute("CREATE TABLE stats_item (other TEXT)")
        _ = try await connection.checkpoint()
        let stats = ListeningStatsStore(carrier: KeyValueStatsCarrier(store: InMemoryCloudStore()), database: database,
                                        history: ListeningStatsSyncTests.RecordingHistory())
        #expect(stats.ownData.secondsPerDay["2026-10-04"] == 300, "the precondition: the start read the day table")
        #expect(await stats.rekeyItems(Self.map) == nil, "the precondition: the item table is unread")

        try await connection.execute("DROP TABLE stats_day")
        try await connection.execute("CREATE TABLE stats_day (other TEXT)")
        try await connection.execute("DROP TABLE stats_item")
        let items = try await KeyedRowStore<Int>(connection: connection, table: .statsItem)
        _ = try await items.apply(previous: [:], current: [old: 2400])
        _ = try await connection.checkpoint()
        let moved = try #require(await stats.rekeyItems(Self.map), "a day table read at the start held the read again")
        #expect(moved.changed == 1)
        #expect(stats.ownData.secondsPerItem[new] == 2400)
        #expect(stats.ownData.secondsPerDay["2026-10-04"] == 300, "the day table read at the start stays")
        await stats.awaitPendingWrites()
    }

    /// Which stores the pass names, held in the sources: a store that keeps
    /// `sub:` ids and is left out would keep the old key silently.
    @Test("the seam: the steps of the run and the trigger in maintenance", .needsTheSources)
    func theSeam() throws {
        let run = SyncContractFenceTests.stripped(try String(
            contentsOf: SourceTree.root.appendingPathComponent("Sources/Networking/NavidromeRekeyRun.swift"), encoding: .utf8))
        for name in ["queue", "context", "stands", "stats", "pending", "choices", "playlists", "downloads"] {
            #expect(run.contains("Step(name: \"\(name)\""), "the pass leaves out \(name)")
        }
        // Every store with rows says whether its start missed some, so the
        // line of its step names the rows that keep their old ids.
        for name in ["queue", "context", "stats", "pending", "playlists", "downloads"] {
            #expect(run.contains("Step(name: \"\(name)\", missedRows: {"), "\(name) does not say which rows it missed")
        }
        #expect(run.contains("SubsonicProvider.songListRekeyStep,"), "the pass leaves out the kept song list")
        #expect(run.contains("await downloads.ensureScanned()"), "before the scan, no download is known yet")
        #expect(run.contains("downloadsStep(),") && run.contains("= { SubsonicProvider.canRenameCovers }")
                    && run.contains("guard canRename() || !downloads.wouldMove(map) else { return nil }"),
                "the pass's downloads step asks whether the covers can follow")
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
