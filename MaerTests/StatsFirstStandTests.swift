// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// A start without rows (a fresh install) publishes the statistics only
/// after the carrier delivered the far side once: the far side may hold
/// this device's own pot from before, and the start takes it back instead
/// of replacing it unread. A carrier that never delivers ends the wait at
/// its limit; the service reads the own pot it otherwise never lists.
@MainActor
struct StatsFirstStandTests {
    /// A carrier whose far side arrives when the witness says so.
    private final class LateCarrier: StatsCarrier {
        let name = "late-fake"
        let hasRoomLimit = false
        var hasDeliveredFirst = false
        var held: [String: ListeningStatsData] = [:]
        var published: [ListeningStatsData] = []
        var onChange: (@MainActor () -> Void)?
        func publish(_ pot: ListeningStatsData, deviceId: String, by caller: String) { published.append(pot) }
        func pots() -> [String: ListeningStatsData] { held }
        func start(onChange: @escaping @MainActor () -> Void) { self.onChange = onChange }
        func stop() {}
        func refresh(by caller: String) async {}
    }

    private static let old = ListeningStatsData(secondsPerDay: ["2026-01-02": 900],
                                                secondsPerItem: ["rss:first-stand:old": 900])

    private static func freshDatabase(_ name: String) throws -> (MaerDatabase, URL) {
        let directory = try NavidromeRekeyTests.temporaryDirectory(name)
        return (MaerDatabase(path: directory.appendingPathComponent("maer.sqlite").path), directory)
    }

    @Test("ein Start ohne Zeilen wartet auf den ersten Stand des Traegers, sonst nicht")
    func whoWaits() {
        let seen = ListeningStatsData(secondsPerDay: ["d": 1], secondsPerItem: [:])
        let table: [(RowBase<ListeningStatsData>, Bool, Bool)] = [
            (.fresh, false, true),
            (.fresh, true, false),
            (.unknown(seen: nil), false, true),
            (.unknown(seen: seen), false, false),
            (.known(seen), false, false),
        ]
        for (base, delivered, waits) in table {
            let takesBack = ListeningStatsSync.takesOwnPotBack(base)
            #expect(ListeningStatsSync.waitsForFirstStand(takesBack: takesBack, delivered: delivered) == waits,
                    "\(base.basis) delivered=\(delivered)")
        }
    }

    @Test("dieselbe Frage fuer Halt und Zuruecknehmen: nur ein Start, der keine Zeile lesen konnte, nimmt den Topf zurueck")
    func whoTakesThePotBack() {
        let seen = ListeningStatsData(secondsPerDay: ["d": 1], secondsPerItem: [:])
        let pot = ListeningStatsData(secondsPerDay: ["d": 5], secondsPerItem: [:])
        let table: [(RowBase<ListeningStatsData>, Bool)] = [
            (.fresh, true),
            (.unknown(seen: nil), true),
            (.unknown(seen: seen), false),
            (.known(seen), false),
        ]
        for (base, takes) in table {
            let takesBack = ListeningStatsSync.takesOwnPotBack(base)
            #expect(takesBack == takes, "\(base.basis)")
            #expect(ListeningStatsSync.waitsForFirstStand(takesBack: takesBack, delivered: false) == takes, "\(base.basis)")
            #expect((ListeningStatsSync.adoptedOwnPot(takesBack: takesBack, own: seen, pot: pot) != nil) == takes,
                    "\(base.basis)")
        }
    }

    @Test("nach einer Neuinstallation wird der spaet eintreffende eigene Topf zurueckgenommen, nicht ueberschrieben")
    func aLatePotIsTakenBackNotReplaced() async throws {
        let restoreSwitch = SyncSwitchProbe.armOn()
        defer { restoreSwitch() }
        let (database, directory) = try Self.freshDatabase("first-stand-late")
        defer { try? FileManager.default.removeItem(at: directory) }
        let carrier = LateCarrier()
        let stats = ListeningStatsStore(carrier: carrier, database: database,
                                        history: ListeningStatsSyncTests.RecordingHistory())
        stats.start()
        stats.addSeconds(30, itemId: "rss:first-stand:new")
        stats.flush()
        await stats.awaitPendingWrites()
        #expect(carrier.published.isEmpty, "nothing is published before the far side was read")

        carrier.held[SyncHistoryStore.deviceId] = Self.old
        carrier.hasDeliveredFirst = true
        carrier.onChange?()
        await stats.awaitPendingWrites()
        #expect(stats.ownData.secondsPerItem["rss:first-stand:old"] == 900, "the pot from before is taken back")
        #expect(stats.ownData.secondsPerItem["rss:first-stand:new"] == 30, "what this run counted stays")
        let sent = try #require(carrier.published.last)
        #expect(sent.secondsPerDay["2026-01-02"] == 900, "the published pot keeps the days from before")
    }

    @Test("nach dem Halt kommt der Topf von vorher als Summe dazu: derselbe Tag und derselbe Titel ergeben 930")
    func theHeldStartAddsThePot() async throws {
        let restoreSwitch = SyncSwitchProbe.armOn()
        defer { restoreSwitch() }
        let (database, directory) = try Self.freshDatabase("first-stand-sum")
        defer { try? FileManager.default.removeItem(at: directory) }
        let carrier = LateCarrier()
        let stats = ListeningStatsStore(carrier: carrier, database: database,
                                        history: ListeningStatsSyncTests.RecordingHistory())
        stats.start()
        let title = "rss:first-stand:same"
        stats.addSeconds(30, itemId: title)
        stats.flush()
        await stats.awaitPendingWrites()
        let today = try #require(stats.ownData.secondsPerDay.first { $0.value == 30 }?.key, "the precondition: one day counted")

        carrier.held[SyncHistoryStore.deviceId] = ListeningStatsData(secondsPerDay: [today: 900], secondsPerItem: [title: 900])
        carrier.hasDeliveredFirst = true
        carrier.onChange?()
        await stats.awaitPendingWrites()
        #expect(stats.ownData.secondsPerDay[today] == 930, "the same day before and after")
        #expect(stats.ownData.secondsPerItem[title] == 930, "the same title before and after")
    }

    /// A fresh start, held, takes the first carrier's pot back as a sum and
    /// publishes; the write has not landed, so the rows still count as
    /// fresh, and the store takes another carrier holding the same history.
    /// Returns the store and the day counted.
    private func secondCarrierAfterSum(firstPot: (String) -> ListeningStatsData?,
                                       secondPot: (String) -> ListeningStatsData,
                                       name: String) throws -> (ListeningStatsStore, String, URL) {
        let (database, directory) = try Self.freshDatabase(name)
        let first = LateCarrier()
        let stats = ListeningStatsStore(carrier: first, database: database,
                                        history: ListeningStatsSyncTests.RecordingHistory())
        stats.start()
        stats.addSeconds(30, itemId: "rss:first-stand:same")
        let today = try #require(stats.ownData.secondsPerDay.first { $0.value == 30 }?.key, "the precondition: one day counted")
        first.held[SyncHistoryStore.deviceId] = firstPot(today)
        first.hasDeliveredFirst = true
        first.onChange?()
        #expect(!first.published.isEmpty, "the precondition: the first carrier got the pot")

        let second = LateCarrier()
        stats.follow(second, signedIn: true, by: "witness")
        second.held[SyncHistoryStore.deviceId] = secondPot(today)
        second.hasDeliveredFirst = true
        second.onChange?()
        return (stats, today, directory)
    }

    @Test("nach dem ersten Veroeffentlichen addiert kein Halt mehr: ein zweiter Traeger mit demselben Tag zaehlt ihn einmal")
    func theSumRunsBeforeTheFirstPublishOnly() async throws {
        let restoreSwitch = SyncSwitchProbe.armOn()
        defer { restoreSwitch() }
        let title = "rss:first-stand:same"
        let history = { (day: String) in ListeningStatsData(secondsPerDay: [day: 900], secondsPerItem: [title: 900]) }
        let (stats, today, directory) = try secondCarrierAfterSum(firstPot: history, secondPot: history,
                                                                 name: "first-stand-twice")
        defer { try? FileManager.default.removeItem(at: directory) }
        await stats.awaitPendingWrites()
        #expect(stats.ownData.secondsPerDay[today] == 930, "the day counts once, not 1830")
        #expect(stats.ownData.secondsPerItem[title] == 930, "the title counts once, not 1830")
    }

    /// The publish after the sum waits: the stock belongs to another account
    /// than the one signed in, and the shelf the handing over writes to is
    /// not writable. The sum stands in the stock all the same, so the second
    /// carrier's pot with the same history is not added again.
    @Test("haelt das Veroeffentlichen nach der Summe, weil der Besitzer wartet, addiert der naechste Traeger nicht noch einmal")
    func aWaitingOwnerKeepsTheSumOnce() async throws {
        let restoreSwitch = SyncSwitchProbe.armOn()
        defer { restoreSwitch() }
        let (database, directory) = try Self.freshDatabase("first-stand-owner")
        defer { try? FileManager.default.removeItem(at: directory) }
        let shelf = try #require(database.restingShelf)
        try shelf.setHolding(.init(owner: "account-a"), of: "stats")
        let manager = FileManager.default
        let locked = [shelf.directory.appendingPathComponent("stats"), shelf.directory]
        for folder in locked { try manager.setAttributes([.posixPermissions: 0o555], ofItemAtPath: folder.path) }
        defer { for folder in locked { try? manager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path) } }

        let first = LateCarrier()
        let stats = ListeningStatsStore(carrier: first, database: database,
                                        history: ListeningStatsSyncTests.RecordingHistory(),
                                        identity: { "account-b" }, shelf: shelf)
        stats.start()
        let title = "rss:first-stand:same"
        stats.addSeconds(30, itemId: title)
        let today = try #require(stats.ownData.secondsPerDay.first { $0.value == 30 }?.key, "the precondition: one day counted")
        let history = ListeningStatsData(secondsPerDay: [today: 900], secondsPerItem: [title: 900])
        first.held[SyncHistoryStore.deviceId] = history
        first.hasDeliveredFirst = true
        first.onChange?()
        #expect(stats.ownData.secondsPerDay[today] == 930, "the precondition: the sum")
        #expect(first.published.isEmpty, "the precondition: the publish waits for the owner")

        let second = LateCarrier()
        stats.follow(second, signedIn: true, by: "witness")
        second.held[SyncHistoryStore.deviceId] = history
        second.hasDeliveredFirst = true
        second.onChange?()
        await stats.awaitPendingWrites()
        #expect(stats.ownData.secondsPerDay[today] == 930, "the day counts once, not 1830")
        #expect(stats.ownData.secondsPerItem[title] == 930, "the title counts once, not 1830")
    }

    @Test("ein leerer erster Topf: nach dem Veroeffentlichen nimmt der zweite Traeger das Maximum, dieser Lauf faellt auf einem gemeinsamen Tag weg")
    func anEmptyFirstPotTakesTheLargerValueLater() async throws {
        let restoreSwitch = SyncSwitchProbe.armOn()
        defer { restoreSwitch() }
        let title = "rss:first-stand:same"
        let (stats, today, directory) = try secondCarrierAfterSum(
            firstPot: { _ in nil },
            secondPot: { day in ListeningStatsData(secondsPerDay: [day: 900], secondsPerItem: [title: 900]) },
            name: "first-stand-empty")
        defer { try? FileManager.default.removeItem(at: directory) }
        await stats.awaitPendingWrites()
        // Chosen: the sum would be right only while the second carrier holds
        // nothing of this run; a switch back to the first would count it twice.
        #expect(stats.ownData.secondsPerDay[today] == 900, "the larger value, this run's 30 s are under it")
        #expect(stats.ownData.secondsPerItem[title] == 900)
    }

    @Test("ein Traeger, der nie liefert, haelt den Topf nur bis zur Frist")
    func theWaitEndsAtItsLimit() async throws {
        let restoreSwitch = SyncSwitchProbe.armOn()
        defer { restoreSwitch() }
        let (database, directory) = try Self.freshDatabase("first-stand-limit")
        defer { try? FileManager.default.removeItem(at: directory) }
        let carrier = LateCarrier()
        let stats = ListeningStatsStore(carrier: carrier, database: database,
                                        history: ListeningStatsSyncTests.RecordingHistory(),
                                        firstStandLimit: .milliseconds(200))
        stats.start()
        stats.addSeconds(30, itemId: "rss:first-stand:limit")
        stats.flush()
        #expect(carrier.published.isEmpty, "the precondition: held at first")
        try await Task.sleep(nanoseconds: 300_000_000)
        stats.flush()
        #expect(carrier.published.last?.secondsPerItem["rss:first-stand:limit"] == 30, "the next pause after the limit publishes")
    }

    @Test("CloudKit: der eigene Datensatz von vorher wird gelesen, bevor der neue Topf hinausgeht")
    func cloudKitReadsTheOwnRecordFirst() async throws {
        let restoreSwitch = SyncSwitchProbe.armOn()
        defer { restoreSwitch() }
        let (database, directory) = try Self.freshDatabase("first-stand-cloud")
        defer { try? FileManager.default.removeItem(at: directory) }
        let name = "first-stand-cloud-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let zone = CloudKitStatsCarrierTests.FakeZone()
        let own = SyncHistoryStore.deviceId
        zone.foreignWrite(CloudStatsRecord(deviceId: own, payload: try MaerSyncStatsWire.encode(Self.old), t: 1))
        let carrier = CloudKitStatsCarrier(database: zone, fallback: KeyValueStatsCarrier(store: InMemoryCloudStore()),
                                           defaults: defaults)
        #expect(!carrier.hasDeliveredFirst, "the precondition: nothing fetched yet")
        let stats = ListeningStatsStore(carrier: carrier, database: database,
                                        history: ListeningStatsSyncTests.RecordingHistory())
        stats.start()
        stats.addSeconds(30, itemId: "rss:first-stand:cloud")
        stats.flush()
        // The start's own round runs in a task of its own; the witness asks
        // again until the published pot stands in the zone.
        func standing() -> ListeningStatsData? {
            zone.records[own].flatMap { MaerSyncStatsWire.decode($0.record.payload) }
        }
        // Before the cloud took the own record once the carrier has a
        // ceiling, and only live items travel; the days travel whole.
        func counted(_ pot: ListeningStatsData?) -> Int {
            (pot?.secondsPerDay ?? [:]).filter { $0.key != "2026-01-02" }.values.reduce(0, +)
        }
        for _ in 0..<40 where counted(standing()) < 30 {
            await carrier.refresh(by: "witness")
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        #expect(carrier.hasDeliveredFirst)
        let pot = try #require(standing())
        #expect(pot.secondsPerDay["2026-01-02"] == 900, "the record from before was replaced unread: \(pot.secondsPerDay)")
        #expect(counted(pot) >= 30, "and this run's listening is in it")
    }

    @Test("Mär Sync: der eigene Topf von vorher wird einmal gelesen, und der naechste Schrieb nennt seine Fassung")
    func theServiceReadsTheOwnPotOnce() async throws {
        let name = "first-stand-service-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let transport = MaerSyncCarrierTests.FakeTransport()
        let stored = transport.foreignWrite(kind: MaerSyncSession.statsKind, scope: "dev-a",
                                            body: try MaerSyncStatsWire.encode(Self.old))
        let access = MaerSyncAccess(baseURL: URL(string: "https://sync.example.test")!, token: "a-token")
        let session = MaerSyncSession(transport: transport, announcer: MaerSyncCarrierTests.FakeAnnouncer(),
                                      access: { access }, deviceId: { "dev-a" }, defaults: defaults)
        let carrier = MaerSyncStatsCarrier(session: session)
        carrier.start {}
        #expect(!carrier.hasDeliveredFirst, "the precondition: not listed yet")
        await session.refresh(by: "witness")
        #expect(carrier.hasDeliveredFirst)
        #expect(carrier.pots()["dev-a"] == Self.old, "the own pot from before is read")
        var grown = Self.old
        grown.secondsPerItem["rss:first-stand:service"] = 30
        carrier.publish(grown, deviceId: "dev-a", by: "witness")
        await session.refresh(by: "witness")
        let write = try #require(transport.writes.last { $0.kind == MaerSyncSession.statsKind })
        #expect(write.ifMatch == stored, "the write names the version it read")
    }

    @Test("der Schluessel-Speicher: der Speicher von iCloud wartet auf seine Meldung, einer im Speicher nicht")
    func theKeyValueStoreWaitsOnlyForICloud() {
        #expect(KeyValueStatsCarrier(store: InMemoryCloudStore()).hasDeliveredFirst, "a store in memory has no far side")
        #expect(!KeyValueStatsCarrier(store: NSUbiquitousKeyValueStore.default).hasDeliveredFirst,
                "the iCloud store has delivered nothing before its change note")
    }
}
#endif
