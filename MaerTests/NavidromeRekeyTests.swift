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

    @Test("die Downloads ziehen um: Ordner, Zeile und Art unter die neue Kennung, die Titel in neuer Form, ein zweiter Lauf null")
    func theDownloadsMove() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("rekey-downloads-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let downloads = directory.appendingPathComponent("Downloads", isDirectory: true)
        let meta = directory.appendingPathComponent("DownloadsMeta", isDirectory: true)
        try FileManager.default.createDirectory(at: meta, withIntermediateDirectories: true)
        let hexAlbum = "sub:album:\(Self.hexAlbum)"
        let plain = "sub:album:a"
        for (id, songs) in [(hexAlbum, [Self.old]), (plain, [Self.old, Self.new]), ("li_book", [Self.old])] {
            let folder = downloads.appendingPathComponent(id, isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data(repeating: 7, count: 10).write(to: folder.appendingPathComponent("0.mp3"))
            try JSONEncoder().encode(Self.detail(id, songs: songs)).write(to: meta.appendingPathComponent("\(id).json"))
        }
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
        for name in ["queue", "context", "stands", "stats", "pending", "downloads"] {
            #expect(run.contains("Step(name: \"\(name)\")"), "the pass leaves out \(name)")
        }
        #expect(run.contains("SubsonicProvider.songListRekeyStep,"), "the pass leaves out the kept song list")
        #expect(run.contains("await downloads.ensureScanned()"), "before the scan, no download is known yet")
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
