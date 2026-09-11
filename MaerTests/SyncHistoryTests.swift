// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// Pure entry creation, the 50-run ring buffer, JSON persistence and the
/// permanence of guard entries (S20's final form).
struct SyncHistoryTests {
    private func entry(minutesAgo: Double, guardNote: String? = nil) -> SyncHistoryEntry {
        SyncHistory.entry(
            service: .gpodder, direction: .both,
            counters: [.init(key: .subscriptionsUp, value: 2),
                       .init(key: .positionsUp, value: 1299),
                       .init(key: .positionsDown, value: 0)],
            duration: 1.5, guardNote: guardNote, deviceId: "dev-1",
            startedAt: Date(timeIntervalSinceNow: -minutesAgo * 60))
    }

    @Test("entry keeps only non-zero counters, in display order")
    func entryCounters() {
        let e = entry(minutesAgo: 0)
        #expect(e.counters.map(\.key) == [.subscriptionsUp, .positionsUp])
        #expect(e.counters.map(\.value) == [2, 1299])
        #expect(e.deviceId == "dev-1")
    }

    // Log-First: a sync that removed subscriptions must carry the removed feeds
    // and non-zero removal counters into a visible entry (the silent-loss gap).
    @Test("removed subscriptions surface as counters + named feeds")
    func removedFeedsAndCounters() {
        let e = SyncHistory.entry(
            service: .gpodder, direction: .both,
            counters: [.init(key: .subscriptionsRemovedLocally, value: 2),
                       .init(key: .subscriptionsRemovedFromServer, value: 0)],
            duration: 0.4,
            removedFeeds: ["Serial — https://feeds.serial.example/rss",
                           "Reply All — https://feeds.replyall.example/rss"],
            deviceId: "dev-1")
        // Zero counter dropped, the non-zero removal counter kept.
        #expect(e.counters.map(\.key) == [.subscriptionsRemovedLocally])
        #expect(e.removedFeeds?.count == 2)
    }

    @Test("no removals → removedFeeds is nil, not an empty list")
    func emptyRemovedFeedsIsNil() {
        let e = SyncHistory.entry(
            service: .gpodder, direction: .both,
            counters: [.init(key: .subscriptionsUp, value: 1)],
            duration: 0.2, removedFeeds: [], deviceId: "dev-1")
        #expect(e.removedFeeds == nil)
    }

    @Test("ring buffer keeps the newest 50")
    func ringBuffer() {
        let many = (0..<60).map { entry(minutesAgo: Double($0)) }
        let trimmed = SyncHistory.trimmed(many)
        #expect(trimmed.count == SyncHistory.ringLimit)
        // Newest first, and the oldest ten fell out.
        #expect(trimmed.first?.startedAt == many.first?.startedAt)
        #expect(!trimmed.contains { $0.startedAt == many.last?.startedAt })
    }

    /// The store's home for one case: a database file and a directory of
    /// its own, with the two documents of the builds before beside each
    /// other as they were.
    private struct Home {
        let directory: URL
        var database: MaerDatabase { MaerDatabase(path: directory.appendingPathComponent("maer.sqlite").path) }
        var document: URL { directory.appendingPathComponent("syncHistory.json") }
        var checkedDocument: URL { directory.appendingPathComponent("syncHistory.lastchecked.json") }
        @MainActor func store() -> SyncHistoryStore {
            SyncHistoryStore(database: database, ablage: Ablage(directory: directory))
        }
        func remove() { try? FileManager.default.removeItem(at: directory) }
    }

    private func home() throws -> Home {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("synchistory-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return Home(directory: directory)
    }

    @MainActor
    @Test("store persists across relaunch; guard entries stay as marked entries")
    func storeRoundTripAndGuardPermanence() async throws {
        let home = try home()
        defer { home.remove() }

        let store = home.store()
        store.append(entry(minutesAgo: 2, guardNote: "Mass delete skipped"))
        store.append(entry(minutesAgo: 1))

        // "Relaunch": a fresh store on the same rows sees both entries, the
        // guard entry still marked. It never expires with later clean syncs.
        // Writes go through the keeper's chain; the relaunch must see them.
        await store.awaitPendingWrites()
        let relaunched = home.store()
        #expect(relaunched.entries.count == 2)
        #expect(relaunched.entries.last?.guardNote == "Mass delete skipped")
        #expect(!FileManager.default.fileExists(atPath: home.document.path), "the document is history")
    }

    /// A `.music` entry (Y27 counters) survives the
    /// persistence round-trip exactly like the older services.
    @MainActor
    @Test("a .music entry persists across relaunch with its counters")
    func musicEntryRoundTrip() async throws {
        let home = try home()
        defer { home.remove() }

        let store = home.store()
        store.append(SyncHistory.entry(
            service: .music, direction: .down,
            counters: [.init(key: .albumsUpdated, value: 42),
                       .init(key: .songsUpdated, value: 512)],
            duration: 2.0, deviceId: "dev-1"))

        await store.awaitPendingWrites()
        let relaunched = home.store()
        #expect(relaunched.entries.count == 1)
        #expect(relaunched.entries.first?.service == .music)
        #expect(relaunched.entries.first?.counters.map(\.value) == [42, 512])
    }

    /// `noteChecked` records a per-service "last checked" stamp that
    /// leaves NO ring entry and survives a relaunch.
    @MainActor
    @Test("noteChecked stamps a service without a ring entry, and persists")
    func lastCheckedPersistsWithoutEntry() async throws {
        let home = try home()
        defer { home.remove() }
        let when = Date(timeIntervalSince1970: 1_700_000_000)
        let store = home.store()
        store.noteChecked(.music, at: when)
        #expect(store.entries.isEmpty)   // a check is not a ring entry
        #expect(store.lastChecked["music"] == when)

        await store.awaitPendingWrites()
        let relaunched = home.store()
        #expect(relaunched.entries.isEmpty)
        #expect(relaunched.lastChecked["music"] == when)
    }

    /// The stamp only moves forward. A stale/out-of-order check never rewinds
    /// it, and an append also refreshes the service's stamp.
    @MainActor
    @Test("last-checked is monotonic; append refreshes the stamp")
    func lastCheckedMonotonicAndAppend() throws {
        let home = try home()
        defer { home.remove() }
        let newer = Date(timeIntervalSince1970: 2_000)
        let older = Date(timeIntervalSince1970: 1_000)
        let store = home.store()
        store.noteChecked(.absProgress, at: newer)
        store.noteChecked(.absProgress, at: older)   // ignored (backwards)
        #expect(store.lastChecked["absProgress"] == newer)

        let appendedAt = Date(timeIntervalSince1970: 3_000)
        store.append(SyncHistory.entry(service: .absProgress, direction: .up,
                                       counters: [.init(key: .positionsUp, value: 3)],
                                       duration: 0, deviceId: "dev-1", startedAt: appendedAt))
        #expect(store.lastChecked["absProgress"] == appendedAt)
    }

    /// The runners' one rule: a run that moved something is a ring entry,
    /// a clean check only the service's stamp; both refresh the stamp.
    @MainActor
    @Test("record: moved is an entry, clean is only the stamp")
    func recordIsEntryOrStamp() throws {
        let home = try home()
        defer { home.remove() }
        let store = home.store()
        let checkedAt = Date(timeIntervalSince1970: 5_000)
        store.record(SyncHistory.entry(service: .gpodder, direction: .both, counters: [],
                                       duration: 0, deviceId: "dev-1", startedAt: checkedAt), moved: false)
        #expect(store.entries.isEmpty, "a clean check leaves no ring entry")
        #expect(store.lastChecked["gpodder"] == checkedAt)
        let movedAt = Date(timeIntervalSince1970: 6_000)
        store.record(SyncHistory.entry(service: .gpodder, direction: .both,
                                       counters: [.init(key: .positionsUp, value: 2)],
                                       duration: 0, deviceId: "dev-1", startedAt: movedAt), moved: true)
        #expect(store.entries.count == 1)
        #expect(store.lastChecked["gpodder"] == movedAt)
    }

    /// The two documents of the builds before are poured into their rows
    /// once, set aside and taken out of the backup; from then on the rows
    /// are the truth and a stale copy beside them changes nothing.
    @MainActor
    @Test("both documents are poured once into their rows and set aside")
    func documentsArePouredOnceAndSetAside() async throws {
        let home = try home()
        defer { home.remove() }
        let old = entry(minutesAgo: 3, guardNote: "kept")
        let when = Date(timeIntervalSince1970: 1_700_000_000)
        try JSONEncoder().encode([old]).write(to: home.document)
        try JSONEncoder().encode(["music": when]).write(to: home.checkedDocument)

        let store = home.store()
        #expect(store.entries.map(\.id) == [old.id])
        #expect(store.lastChecked["music"] == when)
        await store.awaitPendingWrites()
        for document in [home.document, home.checkedDocument] {
            let aside = document.appendingPathExtension("migrated")
            #expect(!FileManager.default.fileExists(atPath: document.path))
            #expect(FileManager.default.fileExists(atPath: aside.path), "set aside, never deleted: \(document.lastPathComponent)")
            #expect(DocumentMigration.isExcludedFromBackup(aside))
        }
        // A stale copy beside the rows changes nothing on the next start.
        try JSONEncoder().encode([entry(minutesAgo: 1)]).write(to: home.document)
        let relaunched = home.store()
        #expect(relaunched.entries.map(\.id) == [old.id], "the rows win")
        #expect(relaunched.entries.first?.guardNote == "kept")
        #expect(relaunched.lastChecked["music"] == when)
    }

    /// An entry this build cannot decode (a service case it does not know,
    /// the rollback case) is one skipped row: the rest of the ring stays,
    /// and the first write of this run removes nothing it never saw, so
    /// the row of the newer build survives the rollback.
    @MainActor
    @Test("an unreadable entry is one skipped row, not the whole ring")
    func anUnknownServiceSkipsOneRow() async throws {
        let home = try home()
        defer { home.remove() }
        let known = entry(minutesAgo: 2)
        let alien = Alien(id: UUID(), deviceId: "dev-2", startedAt: Date(), duration: 0,
                          service: "spaceship", direction: "both", counters: [], error: nil,
                          guardNote: nil, removedFeeds: nil)
        let rows = try await KeyedRowStore<Alien>(connection: try home.database.connection(), table: .syncHistory)
        try await rows.replaceAll([known.id.uuidString: Alien(known), alien.id.uuidString: alien])

        let store = home.store()
        #expect(store.entries.map(\.id) == [known.id], "the readable entry stays, the unreadable one is skipped")
        store.append(entry(minutesAgo: 1))
        await store.awaitPendingWrites()
        #expect(try await rows.count() == 3, "the row this build cannot read is left in place")
    }

    /// The row shape of an entry, as a build that knows another service
    /// case would write it.
    private nonisolated struct Alien: Codable, Equatable, Sendable {
        nonisolated struct Counter: Codable, Equatable, Sendable { let key: String; let value: Int }
        let id: UUID
        let deviceId: String
        let startedAt: Date
        let duration: TimeInterval
        let service: String
        let direction: String
        let counters: [Counter]
        let error: String?
        let guardNote: String?
        let removedFeeds: [String]?

        init(id: UUID, deviceId: String, startedAt: Date, duration: TimeInterval, service: String,
             direction: String, counters: [Counter], error: String?, guardNote: String?, removedFeeds: [String]?) {
            self.id = id; self.deviceId = deviceId; self.startedAt = startedAt; self.duration = duration
            self.service = service; self.direction = direction; self.counters = counters
            self.error = error; self.guardNote = guardNote; self.removedFeeds = removedFeeds
        }

        init(_ entry: SyncHistoryEntry) {
            self.init(id: entry.id, deviceId: entry.deviceId, startedAt: entry.startedAt, duration: entry.duration,
                      service: entry.service.rawValue, direction: entry.direction.rawValue,
                      counters: entry.counters.map { Counter(key: $0.key.rawValue, value: $0.value) },
                      error: entry.error, guardNote: entry.guardNote, removedFeeds: entry.removedFeeds)
        }
    }

    /// An unreadable history file is parked as evidence, the
    /// store starts empty, and the next append begins a fresh ring.
    @MainActor
    @Test("a corrupt history file is parked, not silently overwritten")
    func corruptFileParked() async throws {
        let home = try home()
        defer { home.remove() }
        let parked = home.document.appendingPathExtension("corrupt")
        try Data("not json".utf8).write(to: home.document)

        let store = home.store()
        #expect(store.entries.isEmpty)
        #expect(FileManager.default.fileExists(atPath: parked.path))

        store.append(SyncHistory.entry(service: .music, direction: .down,
                                       counters: [], duration: 0, deviceId: "dev-1"))
        await store.awaitPendingWrites()
        let relaunched = home.store()
        #expect(relaunched.entries.count == 1)
        #expect(FileManager.default.fileExists(atPath: parked.path), "the evidence stays, it is never migrated")
    }
}
#endif
