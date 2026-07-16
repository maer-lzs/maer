#if canImport(Testing)
import Testing
import Foundation
@testable import ABSPlayer

/// Teil 1 (global Up-Next): the queue holds ids of ALL media types, dedups by
/// podcast twin (rss:/abspod:), enforces "heard = flies out" via markedPlayed,
/// and migrates the former podcast-only queue file once.
@MainActor
struct PlayQueueTests {

    /// Fresh, non-persisting queue with an optional twin map.
    private func queue(twins: [String: [String]] = [:]) -> PlayQueue {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("pq-\(UUID().uuidString).json")
        return PlayQueue(fileURL: tmp, persists: false,
                         equivalents: { twins[$0] ?? [$0] })
    }

    @Test("playNext / playLast keep order and never duplicate")
    func orderAndDedup() {
        let q = queue()
        q.playLast("a"); q.playLast("b"); q.playNext("c")
        #expect(q.ids == ["c", "a", "b"])
        q.playNext("a")                       // pull existing to the front
        #expect(q.ids == ["a", "c", "b"])
        q.playLast("a")                        // already present → no-op
        #expect(q.ids == ["a", "c", "b"])
    }

    @Test("remove and markedPlayed drop the entry (invariant c)")
    func removeAndMarkedPlayed() {
        let q = queue()
        ["a", "b", "c"].forEach { q.playLast($0) }
        q.markedPlayed("b")
        #expect(q.ids == ["a", "c"])
        q.remove("a")
        #expect(q.ids == ["c"])
        q.remove("zzz")                        // absent → no-op
        #expect(q.ids == ["c"])
    }

    @Test("removal is equivalence-aware: a twin id takes out both faces")
    func equivalenceAwareRemove() {
        let twins = ["rss:1": ["rss:1", "abspod:1"], "abspod:1": ["rss:1", "abspod:1"]]
        let q = queue(twins: twins)
        q.playLast("abspod:1"); q.playLast("a")
        #expect(q.contains("rss:1"))           // queued under its twin
        q.markedPlayed("rss:1")                // mark via the OTHER face
        #expect(q.ids == ["a"])
        // playLast must not re-add a twin already present.
        q.playLast("abspod:1")
        q.playLast("rss:1")
        #expect(q.ids.filter { $0.hasPrefix("rss:") || $0.hasPrefix("abspod:") }.count == 1)
    }

    @Test("move reorders")
    func move() {
        let q = queue()
        ["a", "b", "c"].forEach { q.playLast($0) }
        q.move(from: IndexSet(integer: 0), to: 3)   // a to the end
        #expect(q.ids == ["b", "c", "a"])
    }

    @Test("one-time migration adopts the former podcast-only queue file")
    func migration() throws {
        let dir = FileManager.default.temporaryDirectory
        let legacy = dir.appendingPathComponent("legacy-\(UUID().uuidString).json")
        let current = dir.appendingPathComponent("current-\(UUID().uuidString).json")
        try JSONEncoder().encode(["rss:x", "abspod:y"]).write(to: legacy)
        // New file absent → adopt legacy, persist, delete legacy.
        let q = PlayQueue(fileURL: current, migrateFrom: legacy, persists: true)
        #expect(q.ids == ["rss:x", "abspod:y"])
        #expect(FileManager.default.fileExists(atPath: current.path))
        #expect(!FileManager.default.fileExists(atPath: legacy.path))
        // A second instance now loads the migrated file directly.
        let q2 = PlayQueue(fileURL: current, migrateFrom: legacy, persists: true)
        #expect(q2.ids == ["rss:x", "abspod:y"])
        try? FileManager.default.removeItem(at: current)
    }

    @Test("clear empties the queue")
    func clear() {
        let q = queue()
        ["a", "b"].forEach { q.playLast($0) }
        q.clear()
        #expect(q.isEmpty)
    }
}
#endif
