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
}
#endif
