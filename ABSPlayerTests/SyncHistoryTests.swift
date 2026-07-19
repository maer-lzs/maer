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
