// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later

#if canImport(Testing)
import Testing
import Foundation
@testable import ABSPlayer

/// F9: pure entry creation, the 50-run ring buffer, JSON persistence and the
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

    @MainActor
    @Test("store persists across relaunch; guard entries stay as marked entries")
    func storeRoundTripAndGuardPermanence() {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("syncHistory-test-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }

        let store = SyncHistoryStore(fileURL: file)
        store.append(entry(minutesAgo: 2, guardNote: "Mass delete skipped"))
        store.append(entry(minutesAgo: 1))

        // "Relaunch": a fresh store on the same file sees both entries, the
        // guard entry still marked — it never expires with later clean syncs.
        let relaunched = SyncHistoryStore(fileURL: file)
        #expect(relaunched.entries.count == 2)
        #expect(relaunched.entries.last?.guardNote == "Mass delete skipped")
    }

    /// Y36 candidate check: a `.music` entry (Y27 counters) survives the
    /// persistence round-trip exactly like the older services.
    @MainActor
    @Test("a .music entry persists across relaunch with its counters")
    func musicEntryRoundTrip() {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("syncHistory-test-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }

        let store = SyncHistoryStore(fileURL: file)
        store.append(SyncHistory.entry(
            service: .music, direction: .down,
            counters: [.init(key: .albumsUpdated, value: 42),
                       .init(key: .songsUpdated, value: 512)],
            duration: 2.0, deviceId: "dev-1"))

        let relaunched = SyncHistoryStore(fileURL: file)
        #expect(relaunched.entries.count == 1)
        #expect(relaunched.entries.first?.service == .music)
        #expect(relaunched.entries.first?.counters.map(\.value) == [42, 512])
    }

    /// Y48/Y50: `noteChecked` records a per-service "last checked" stamp that
    /// leaves NO ring entry and survives a relaunch.
    @MainActor
    @Test("noteChecked stamps a service without a ring entry, and persists")
    func lastCheckedPersistsWithoutEntry() {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("syncHistory-test-\(UUID().uuidString).json")
        let checked = file.deletingPathExtension().appendingPathExtension("lastchecked.json")
        defer {
            try? FileManager.default.removeItem(at: file)
            try? FileManager.default.removeItem(at: checked)
        }
        let when = Date(timeIntervalSince1970: 1_700_000_000)
        let store = SyncHistoryStore(fileURL: file)
        store.noteChecked(.music, at: when)
        #expect(store.entries.isEmpty)   // a check is not a ring entry
        #expect(store.lastChecked["music"] == when)

        let relaunched = SyncHistoryStore(fileURL: file)
        #expect(relaunched.entries.isEmpty)
        #expect(relaunched.lastChecked["music"] == when)
    }

    /// The stamp only moves forward — a stale/out-of-order check never rewinds
    /// it, and an append also refreshes the service's stamp.
    @MainActor
    @Test("last-checked is monotonic; append refreshes the stamp")
    func lastCheckedMonotonicAndAppend() {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("syncHistory-test-\(UUID().uuidString).json")
        let checked = file.deletingPathExtension().appendingPathExtension("lastchecked.json")
        defer {
            try? FileManager.default.removeItem(at: file)
            try? FileManager.default.removeItem(at: checked)
        }
        let newer = Date(timeIntervalSince1970: 2_000)
        let older = Date(timeIntervalSince1970: 1_000)
        let store = SyncHistoryStore(fileURL: file)
        store.noteChecked(.absProgress, at: newer)
        store.noteChecked(.absProgress, at: older)   // ignored (backwards)
        #expect(store.lastChecked["absProgress"] == newer)

        let appendedAt = Date(timeIntervalSince1970: 3_000)
        store.append(SyncHistory.entry(service: .absProgress, direction: .up,
                                       counters: [.init(key: .positionsUp, value: 3)],
                                       duration: 0, deviceId: "dev-1", startedAt: appendedAt))
        #expect(store.lastChecked["absProgress"] == appendedAt)
    }

    /// Y36 (Regel 3): an unreadable history file is parked as evidence, the
    /// store starts empty, and the next append begins a fresh ring.
    @MainActor
    @Test("a corrupt history file is parked, not silently overwritten")
    func corruptFileParked() {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("syncHistory-test-\(UUID().uuidString).json")
        let parked = file.appendingPathExtension("corrupt")
        defer {
            try? FileManager.default.removeItem(at: file)
            try? FileManager.default.removeItem(at: parked)
        }
        try? Data("not json".utf8).write(to: file)

        let store = SyncHistoryStore(fileURL: file)
        #expect(store.entries.isEmpty)
        #expect(FileManager.default.fileExists(atPath: parked.path))

        store.append(SyncHistory.entry(service: .music, direction: .down,
                                       counters: [], duration: 0, deviceId: "dev-1"))
        let relaunched = SyncHistoryStore(fileURL: file)
        #expect(relaunched.entries.count == 1)
    }
}
#endif
