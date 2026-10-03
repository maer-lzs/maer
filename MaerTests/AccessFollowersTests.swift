// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// Eine Anmeldung bei Mär Sync im laufenden Prozess bringt jede Familie
/// sofort auf den Dienst, eine Abmeldung sofort zurueck, ohne Neustart.
/// Vorher waehlte jeder Laeufer seinen Traeger einmal, beim Bau, und eine
/// Familie, die vor der Anmeldung schon gebraucht wurde, blieb bis zum
/// naechsten Start bei iCloud (am Geraet: die Abos kamen erst nach einem
/// Neustart).
///
/// Die Fakes nennen sich wie die echten Traeger: ein Name mit dem Stamm
/// des Dienstes ist der Dienst, jeder andere ist es nicht.
@MainActor
struct AccessFollowersTests {
    static let service = MaerSyncCarriers.carrierNameStem
    static let apple = "kvs"

    // MARK: - Die Regel

    @Test("die Regel: wechseln, wenn der gehaltene Weg nicht der des Zugangs ist")
    func theRule() {
        #expect(CarrierWay.isService(carrierName: Self.service))
        #expect(CarrierWay.isService(carrierName: "\(Self.service) signed out"))
        #expect(!CarrierWay.isService(carrierName: "kvs"))
        #expect(!CarrierWay.isService(carrierName: "cloudkit migrating"))
        #expect(!CarrierWay.isService(carrierName: "kvs fallback"))
        #expect(CarrierWay.mustChange(holdsService: false, signedIn: true))
        #expect(CarrierWay.mustChange(holdsService: true, signedIn: false))
        #expect(!CarrierWay.mustChange(holdsService: true, signedIn: true), "a second sign-in changes nothing")
        #expect(!CarrierWay.mustChange(holdsService: false, signedIn: false))
    }

    // MARK: - Die Staende

    private final class StandFake: StandCarrier {
        let name: String
        var hasRoomLimit = false
        var held: [String: [Double]] = [:]
        var writes = 0
        var onChange: (@MainActor () -> Void)?
        init(_ name: String) { self.name = name }
        func stands() -> [String: [Double]] { held }
        func write(upserts: [String: [Double]], removing: Set<String>, by caller: String) {
            writes += 1
            for id in removing { held[id] = nil }
            for (id, entry) in upserts { held[id] = entry }
        }
        func start(onChange: @escaping @MainActor () -> Void) { self.onChange = onChange }
        var stops = 0
        func stop() { stops += 1 }
        func refresh(by caller: String) async {}
    }

    @Test("Staende: Wechsel im Lauf auf den Dienst und zurueck, nichts geht verloren, der alte Traeger bewegt nichts mehr")
    func theStandsFollowBothWays() throws {
        let restoreSwitch = SyncSwitchProbe.armOn()
        defer { restoreSwitch() }
        #expect(AppStorageKeys.syncAcrossDevicesEnabled, "ohne den Schalter misst der Fall nichts")
        let mine = "rss:follow:\(UUID().uuidString)"
        let theirs = "rss:follow:\(UUID().uuidString)"
        let stray = "rss:follow:\(UUID().uuidString)"
        defer { for id in [mine, theirs, stray] { ListeningStore.clearBackup(id) } }
        let now = Date().timeIntervalSince1970 * 1000
        ListeningStore.store(mine, entry: [420, now, 3_600])

        let apple = StandFake(Self.apple)
        let sync = PodcastCloudSync(carrier: apple)
        sync.start()
        let oldWake = try #require(apple.onChange, "the first carrier was started")
        #expect(apple.held[mine]?[0] == 420)

        // The service holds a stand of another device that this one has
        // never seen: after the change both are on both sides.
        let service = StandFake(Self.service)
        service.held[theirs] = [90, now - 1_000, 1_800]
        sync.follow(service, signedIn: true, by: "witness")
        #expect(service.onChange != nil, "stands: the service carrier was not started")
        #expect(apple.stops == 1, "stands: the old carrier was not stopped")
        #expect(service.held[mine]?[0] == 420, "stands: the own stand did not reach the service")
        #expect(ListeningStore.positions()[theirs]?[0] == 90, "stands: what the service held did not arrive")
        #expect(service.held[theirs]?[0] == 90, "stands: the service lost what it held")

        // A round the old carrier still had running comes back now.
        let writesBefore = service.writes
        apple.held[stray] = [77, now + 5_000, 600]
        oldWake()
        #expect(service.writes == writesBefore, "stands: the old carrier made the runner write")
        #expect(ListeningStore.positions()[stray] == nil, "stands: the old carrier's round was applied")

        // And back: signed out, Apple carries again, with everything.
        let back = StandFake(Self.apple)
        sync.follow(back, signedIn: false, by: "witness")
        #expect(back.onChange != nil, "stands: the way back was not started")
        #expect(back.held[mine]?[0] == 420 && back.held[theirs]?[0] == 90, "stands: the way back lost a stand")
    }

    // MARK: - Der Anspruch

    private final class ClaimFake: ClaimCarrier {
        let name: String
        var held: [PlaybackClaim] = []
        var onChange: (@MainActor () -> Void)?
        let heartbeatSeconds: Double = 10
        init(_ name: String) { self.name = name }
        func write(_ claim: PlaybackClaim) { held.removeAll { $0.deviceId == claim.deviceId }; held.append(claim) }
        func claims() -> [PlaybackClaim] { held }
        func remove(deviceId: String) { held.removeAll { $0.deviceId == deviceId } }
        func start(onChange: @escaping @MainActor () -> Void) { self.onChange = onChange }
        var stops = 0
        func stop() { stops += 1 }
    }

    @Test("Anspruch: Wechsel im Lauf auf den Dienst und zurueck, der alte Traeger bewegt nichts mehr")
    func theClaimFollowsBothWays() throws {
        let restoreSwitch = SyncSwitchProbe.armOn()
        defer { restoreSwitch() }
        let now = 1_800_000_000_000.0
        let apple = ClaimFake(Self.apple)
        let sync = PlaybackClaimSync(carrier: apple, deviceId: { "dev-a" }, deviceName: { "A" }, now: { now })
        sync.start()
        let oldWake = try #require(apple.onChange, "the first carrier was started")
        #expect(sync.current == nil)

        let service = ClaimFake(Self.service)
        let other = PlaybackClaim(deviceId: "dev-b", itemId: "rss:b:1", t: now - 1_000, position: 30, deviceName: "B")
        service.held = [other]
        var takeovers = 0
        sync.onForeignClaim = { _ in takeovers += 1 }
        sync.follow(service, signedIn: true, by: "witness")
        #expect(service.onChange != nil, "claim: the service carrier was not started")
        #expect(apple.stops == 1, "claim: the old carrier was not stopped")
        #expect(sync.current == other, "claim: the claim the service holds did not arrive")
        let takeoversAfterChange = takeovers
        #expect(takeoversAfterChange >= 1, "the precondition: the takeover hook is reached at all")

        // The runner always reads its CURRENT carrier, so a late round of
        // the old one cannot bring its own claims in; what it could do is
        // wake the takeover hook once more, and the generation stops that.
        apple.held = [PlaybackClaim(deviceId: "dev-c", itemId: "rss:c:1", t: now, position: 5, deviceName: "C")]
        oldWake()
        #expect(sync.current == other, "claim: the old carrier's round was applied")
        #expect(takeovers == takeoversAfterChange, "claim: the old carrier woke the takeover hook")

        let back = ClaimFake(Self.apple)
        sync.follow(back, signedIn: false, by: "witness")
        #expect(back.onChange != nil, "claim: the way back was not started")
    }

    // MARK: - Die Statistik

    private final class StatsFake: StatsCarrier {
        let name: String
        var held: [String: ListeningStatsData] = [:]
        var published: [ListeningStatsData] = []
        var onChange: (@MainActor () -> Void)?
        let hasRoomLimit = false
        init(_ name: String) { self.name = name }
        func publish(_ pot: ListeningStatsData, deviceId: String, by caller: String) {
            published.append(pot)
            held[deviceId] = pot
        }
        func pots() -> [String: ListeningStatsData] { held }
        func start(onChange: @escaping @MainActor () -> Void) { self.onChange = onChange }
        var stops = 0
        func stop() { stops += 1 }
        func refresh(by caller: String) async {}
    }

    @Test("Statistik: Wechsel im Lauf auf den Dienst und zurueck, der alte Traeger bewegt nichts mehr")
    func theStatsFollowBothWays() throws {
        let restoreSwitch = SyncSwitchProbe.armOn()
        defer { restoreSwitch() }
        let apple = StatsFake(Self.apple)
        let stats = ListeningStatsStore(carrier: apple)
        stats.start()
        let oldWake = try #require(apple.onChange, "the first carrier was started")

        let service = StatsFake(Self.service)
        let day = "2026-10-02"
        service.held["dev-other-\(UUID().uuidString)"] = ListeningStatsData(secondsPerDay: [day: 3_600], secondsPerItem: [:])
        let before = stats.data.secondsPerDay[day] ?? 0
        stats.follow(service, signedIn: true, by: "witness")
        #expect(service.onChange != nil, "stats: the service carrier was not started")
        #expect(apple.stops == 1, "stats: the old carrier was not stopped")
        #expect(!service.published.isEmpty, "stats: the own pot did not reach the service")
        #expect((stats.data.secondsPerDay[day] ?? 0) == before + 3_600, "stats: the other device's pot did not arrive")

        apple.held["dev-stray-\(UUID().uuidString)"] = ListeningStatsData(secondsPerDay: [day: 999], secondsPerItem: [:])
        oldWake()
        #expect((stats.data.secondsPerDay[day] ?? 0) == before + 3_600, "stats: the old carrier's round was applied")

        let back = StatsFake(Self.apple)
        stats.follow(back, signedIn: false, by: "witness")
        #expect(back.onChange != nil, "stats: the way back was not started")
        #expect(!back.published.isEmpty, "stats: the own pot did not reach the way back")
    }

    // MARK: - Die Listen

    private final class PlaylistFake: PlaylistCarrier {
        let name: String
        var snapshot = MaerPlaylistMerge.Snapshot()
        var stores = 0
        var onChange: (@MainActor () -> Void)?
        init(_ name: String) { self.name = name }
        func held() -> MaerPlaylistMerge.Snapshot { snapshot }
        func store(_ snapshot: MaerPlaylistMerge.Snapshot) { self.snapshot = snapshot; stores += 1 }
        func start(onChange: @escaping @MainActor () -> Void) { self.onChange = onChange }
        var stops = 0
        func stop() { stops += 1 }
        func refresh(by caller: String) async {}
    }

    @Test("Listen: Wechsel im Lauf auf den Dienst und zurueck, der alte Traeger bewegt nichts mehr")
    func thePlaylistsFollowBothWays() throws {
        let restoreSwitch = SyncSwitchProbe.armOn()
        defer { restoreSwitch() }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("follow-lists-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = MaerPlaylists(database: MaerDatabase(path: directory.appendingPathComponent("maer.sqlite").path))
        let mine = store.create(name: "Vor der Anmeldung")
        _ = store.add(itemId: "rss:eins", to: mine.id)

        let apple = PlaylistFake(Self.apple)
        let runner = MaerPlaylistCloudSync(carrier: apple, playlists: store)
        runner.start()
        let oldWake = try #require(apple.onChange, "the first carrier was started")

        let service = PlaylistFake(Self.service)
        runner.follow(service, signedIn: true, by: "witness")
        #expect(service.onChange != nil, "playlists: the service carrier was not started")
        #expect(apple.stops == 1, "playlists: the old carrier was not stopped")
        #expect(service.snapshot.lists[mine.id]?.itemIds == ["rss:eins"], "playlists: the own list did not reach the service")

        let storesBefore = service.stores
        var stray = apple.snapshot
        stray.lists["stray-\(UUID().uuidString)"] = .init(name: "Fremd", updatedAt: 9e12, itemIds: ["rss:x"])
        apple.snapshot = stray
        oldWake()
        #expect(service.stores == storesBefore, "playlists: the old carrier made the runner write")
        #expect(!store.playlists.contains { $0.name == "Fremd" }, "playlists: the old carrier's round was applied")

        let back = PlaylistFake(Self.apple)
        runner.follow(back, signedIn: false, by: "witness")
        #expect(back.snapshot.lists[mine.id]?.itemIds == ["rss:eins"], "playlists: the way back lost the list")
    }

    // MARK: - Die Wahlen, der Fall vom Geraet

    /// A key-value carrier under the name of the way it stands for.
    private final class NamedChoiceCarrier: ChoiceCarrier {
        let name: String
        let inner: KeyValueChoiceCarrier
        var onChange: (@MainActor () -> Void)?
        init(_ name: String, _ inner: KeyValueChoiceCarrier) { self.name = name; self.inner = inner }
        func loadBlob() -> [String: Any] { inner.loadBlob() }
        func storeBlob(_ blob: [String: Any]) { inner.storeBlob(blob) }
        func legacyList(forKey key: String) -> [String]? { inner.legacyList(forKey: key) }
        func flush() { inner.flush() }
        func start(onChange: @escaping @MainActor () -> Void) { self.onChange = onChange }
        var stops = 0
        func stop() { stops += 1; inner.stop() }
    }

    private func device(_ carrier: any ChoiceCarrier) -> (sync: UserChoiceCloudSync, defaults: UserDefaults, suite: String) {
        let suite = "follow-choice-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        var clock = 1_000.0
        let sync = UserChoiceCloudSync(defaults: defaults, carrier: carrier, syncEnabled: { true },
                                       now: { clock += 1; return clock })
        return (sync, defaults, suite)
    }

    @Test("Wahlen, der Fall vom Geraet: zuerst ohne Dienst gebraucht, dann angemeldet, Abos und bekannte Server kommen ohne Neustart")
    func theChoicesBringSubscriptionsAndServersAtTheSignIn() throws {
        let serviceStore = UserChoiceFakeCloud()
        let feed = "https://example.org/follow-\(UUID().uuidString).xml"

        // The other device wrote its subscription and a known server over
        // the service.
        let other = device(NamedChoiceCarrier(Self.service, KeyValueChoiceCarrier(store: serviceStore)))
        defer { UserDefaults().removePersistentDomain(forName: other.suite) }
        other.sync.localSubscriptions = { [PodcastSubscriptions.feedKey(feed): feed] }
        other.sync.noteSubscription(feedURL: feed, subscribed: true)
        KnownServers.remember("https://books.example", service: .audiobookshelf, now: 1_700_000_000, defaults: other.defaults)
        other.sync.noteKnownServers()

        // This device used its choices before the sign-in, over Apple.
        let appleStore = UserChoiceFakeCloud()
        let apple = NamedChoiceCarrier(Self.apple, KeyValueChoiceCarrier(store: appleStore))
        let here = device(apple)
        defer { UserDefaults().removePersistentDomain(forName: here.suite) }
        var offered: [String] = []
        here.sync.subscriptionAdopter = { added, _ in offered += added.map(\.feedURL) }
        here.sync.localSubscriptions = { [:] }
        here.sync.start()
        let oldWake = try #require(apple.onChange, "the first carrier was started")
        #expect(offered.isEmpty, "the precondition: over Apple there is nothing to adopt")
        #expect(KnownServers.suggestions(for: .audiobookshelf, defaults: here.defaults).isEmpty)

        here.sync.follow(NamedChoiceCarrier(Self.service, KeyValueChoiceCarrier(store: serviceStore)),
                         signedIn: true, by: "witness")
        #expect(offered == [feed], "choices: the subscription did not arrive at the sign-in")
        #expect(KnownServers.suggestions(for: .audiobookshelf, defaults: here.defaults).map(\.url) == ["https://books.example"],
                "choices: the known server did not arrive at the sign-in")
        #expect(apple.stops == 1, "choices: the old carrier was not stopped")

        // A round the old carrier still had running comes back now, with
        // something new in the store behind it.
        here.defaults.removeObject(forKey: "followStray")
        appleStore.set(["followStray": UserChoiceEntry(value: .bool(true), t: 9e12).plist],
                       forKey: KeyValueChoiceCarrier.blobKey)
        oldWake()
        #expect(here.defaults.object(forKey: "followStray") == nil, "choices: the old carrier's round was applied")
    }

    // MARK: - Die Ruhe des alten Traegers

    /// A key-value store that counts what is written into it.
    private final class CountingStore: UserChoiceCloudStore {
        private var values: [String: Any] = [:]
        var writes = 0
        func dictionary(forKey key: String) -> [String: Any]? { values[key] as? [String: Any] }
        func array(forKey key: String) -> [Any]? { values[key] as? [Any] }
        func set(_ value: Any?, forKey key: String) { writes += 1; values[key] = value }
        func synchronize() -> Bool { true }
        var dictionaryRepresentation: [String: Any] { values }
        func removeObject(forKey key: String) { writes += 1; values[key] = nil }
    }

    @Test("Ruhe: ein gestoppter Schluessel-Traeger schreibt nichts mehr, auch den vorher eingereihten Schrieb nicht, und meldet nichts")
    func aStoppedKeyValueCarrierRests() async throws {
        let store = CountingStore()
        let stands = KeyValueStandCarrier(cloud: store, spacingSeconds: 0.3)
        var wakes = 0
        stands.start { wakes += 1 }
        stands.write(upserts: ["rss:rest:1": [1, 1_000]], removing: [], by: "witness")
        #expect(store.writes == 1, "the first write goes at once")
        stands.write(upserts: ["rss:rest:2": [2, 2_000]], removing: [], by: "witness")
        #expect(store.writes == 1, "the precondition: the second write waits in the queue")
        NotificationCenter.default.post(name: NSUbiquitousKeyValueStore.didChangeExternallyNotification, object: nil)
        for _ in 0..<50 { await Task.yield() }
        #expect(wakes == 1, "the precondition: a delivery reaches a running carrier")

        stands.stop()
        try await Task.sleep(nanoseconds: 700_000_000)
        #expect(store.writes == 1, "stands: the write queued before the stop landed after it")
        stands.write(upserts: ["rss:rest:3": [3, 3_000]], removing: [], by: "witness")
        await stands.refresh(by: "witness")
        NotificationCenter.default.post(name: NSUbiquitousKeyValueStore.didChangeExternallyNotification, object: nil)
        for _ in 0..<50 { await Task.yield() }
        #expect(store.writes == 1, "stands: a stopped carrier wrote")
        #expect(wakes == 1, "stands: a stopped carrier delivered")

        // The other four key-value carriers, stopped, write nothing.
        let stats = KeyValueStatsCarrier(store: store)
        stats.start {}
        stats.stop()
        stats.publish(ListeningStatsData(), deviceId: "dev-rest", by: "witness")
        let claim = KeyValueClaimCarrier(cloud: store)
        claim.start {}
        claim.stop()
        claim.write(PlaybackClaim(deviceId: "dev-rest", itemId: "rss:rest:1", t: 1, position: 1, deviceName: "R"))
        claim.remove(deviceId: "dev-rest")
        let choices = KeyValueChoiceCarrier(store: store)
        choices.start {}
        choices.stop()
        choices.storeBlob(["followRest": 1])
        let lists = KeyValuePlaylistCarrier(store: store)
        lists.start {}
        lists.stop()
        lists.store(MaerPlaylistMerge.Snapshot(lists: ["rest": .init(name: "R", updatedAt: 1, itemIds: ["rss:a"])]))
        #expect(store.writes == 1, "a stopped key-value carrier wrote: \(store.writes - 1) writes")
    }

    @Test("Ruhe: ein gestoppter CloudKit-Traeger holt und sendet nichts mehr, auch den vorher eingereihten Schrieb nicht")
    func aStoppedCloudKitCarrierRests() async throws {
        let suite = "follow-rest-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let database = CloudKitStandCarrierTests.FakeDatabase()
        let carrier = CloudKitStandCarrier(database: database,
                                           fallback: KeyValueStandCarrier(cloud: InMemoryCloudStore(), spacingSeconds: 0),
                                           defaults: defaults)
        var wakes = 0
        carrier.start { wakes += 1 }
        await carrier.refresh(by: "witness")
        database.foreignWrite(CloudStandRecord(itemId: "rss:rest:before", entry: [4, 4_000], tombstone: false))
        await carrier.refresh(by: "witness")
        #expect(wakes == 1, "the precondition: a running carrier fetches and delivers")
        let modifies = database.modifies.count

        // A write queues its send as a task of its own; the stop comes
        // before that task runs.
        carrier.write(upserts: ["rss:rest:cloud": [5, 5_000]], removing: [], by: "witness")
        carrier.stop()
        for _ in 0..<50 { await Task.yield() }
        database.foreignWrite(CloudStandRecord(itemId: "rss:rest:after", entry: [6, 6_000], tombstone: false))
        await carrier.refresh(by: "witness")
        #expect(database.modifies.count == modifies, "cloudkit: the stopped carrier sent")
        #expect(wakes == 1, "cloudkit: the stopped carrier fetched and delivered")
    }

    // MARK: - Die Naht

    /// Every runner that holds a carrier enrolls where its shared instance
    /// is built, and the one place that writes the access moves them. A
    /// sixth way to write the access, or a runner that does not enroll,
    /// brings the class back silently.
    @Test("die Naht: jeder geteilte Laeufer folgt, und nur Anmelden und Abmelden schreiben den Zugang", .needsTheSources)
    func theSeam() throws {
        func code(_ path: String) throws -> String {
            SyncContractFenceTests.stripped(try String(contentsOf: SourceTree.root.appendingPathComponent(path), encoding: .utf8))
        }
        for (path, type) in [("Sources/Networking/PodcastCloudSync.swift", "PodcastCloudSync"),
                             ("Sources/Networking/PlaybackClaimSync.swift", "PlaybackClaimSync"),
                             ("Sources/Models/ListeningStats.swift", "ListeningStatsStore"),
                             ("Sources/Networking/MaerPlaylistCloudSync.swift", "MaerPlaylistCloudSync"),
                             ("Sources/Networking/UserChoiceCloudSync.swift", "UserChoiceCloudSync"),
                             ("Sources/Networking/FeedAuthSync.swift", "FeedAuthSync")] {
            let text = try code(path)
            #expect(text.contains("static let shared = AccessFollowers.enrolled(\(type)("), "\(type) does not enroll")
            #expect(text.contains("extension \(type): AccessFollower"), "\(type) does not follow")
        }
        let signIn = try code("Sources/Networking/MaerSyncSignIn.swift")
        #expect(signIn.components(separatedBy: "AccessFollowers.followAll(by:").count - 1 == 2,
                "sign-in and sign-out both move the runners")
        // Every writer of the access, counted over the whole app.
        let writers = try Self.accessWriters()
        #expect(writers == ["Sources/Networking/MaerSyncSignIn.swift": 3],
                "a writer of the access outside sign-in and sign-out: \(writers)")
    }

    /// Files under `Sources` with the number of lines that write the token
    /// or the address of the access: through the two writers of
    /// `AppStorageKeys`, or past them by the key itself. The keys' own home
    /// is not counted.
    static func accessWriters() throws -> [String: Int] {
        let root = SourceTree.root
        let sources = root.appendingPathComponent("Sources")
        let files = try #require(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
        var found: [String: Int] = [:]
        for case let url as URL in files where url.pathExtension == "swift" && url.lastPathComponent != "AppStorageKeys.swift" {
            let text = SyncContractFenceTests.stripped(try String(contentsOf: url, encoding: .utf8))
            let count = text.split(separator: "\n").filter {
                $0.contains("AppStorageKeys.setMaerSyncToken(") || $0.contains("AppStorageKeys.maerSyncURLValue =")
                    || $0.contains("KeychainKey.maerSyncToken") || $0.contains("AppStorageKeys.maerSyncURL)")
                    || $0.contains("AppStorageKeys.maerSyncURL,")
            }.count
            if count > 0 {
                found[url.resolvingSymlinksInPath().path.replacingOccurrences(of: root.resolvingSymlinksInPath().path + "/", with: "")] = count
            }
        }
        return found
    }
}
#endif
