// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// In-memory storage for tests (class: state can be inspected after the flush).
private final class MemoryStorage: SyncQueueStorage {
    var dict: [String: SyncQueue.PendingUpdate] = [:]
    func load() -> [String: SyncQueue.PendingUpdate] { dict }
    func save(_ pending: [String: SyncQueue.PendingUpdate]) { dict = pending }
    func awaitPendingWrites() async {}
    let startReadFailed = false
}

@MainActor
private final class MockAPI: ProgressSyncAPI {
    var progress: [String: BookProgress] = [:]
    var fetchError: Error?
    var updateError: Error?
    var written: [(itemId: String, currentTime: Double, isFinished: Bool)] = []
    /// Hook to simulate concurrency during the flush
    /// (e.g. the active player removes a queue entry).
    var onUpdate: ((String) async -> Void)?
    /// Runs while the server's states are asked, before they come back.
    var onFetch: (() async -> Void)?

    func fetchAllProgress() async throws -> [String: BookProgress] {
        if let fetchError { throw fetchError }
        await onFetch?()
        return progress
    }

    func updateProgress(itemId: String, currentTime: Double, duration: Double, isFinished: Bool) async throws {
        if let updateError { throw updateError }
        await onUpdate?(itemId)
        written.append((itemId, currentTime, isFinished))
    }
}

private func offlineError() -> Error {
    NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet)
}

/// Tests for the flush procedure of the SyncQueue (rules themselves: SyncRulesTests).
@MainActor
struct SyncQueueFlushTests {

    private func makeQueue() -> (SyncQueue, MemoryStorage, MockAPI) {
        let storage = MemoryStorage()
        return (SyncQueue(storage: storage), storage, MockAPI())
    }

    // MARK: - Every entry to ITS server

    /// The queue holds one entry per TITLE, and a title carries
    /// its source in the id. It nevertheless took ONE client for
    /// everything in it, and both callers passed the main provider. Since the shelf
    /// mixes secondary sources, a `jf:` position thereby landed at the
    /// library server.
    ///
    /// Two halves, and the second is the quieter one: the write went to the
    /// wrong server, AND the check „der Server gewinnt" asked
    /// the same wrong one. For a foreign book nothing stands there, a
    /// missing entry reads as „kein Serverstand", and the protection
    /// silently fell away.
    @Test("every entry goes to the server that its id belongs to")
    func eachEntryGoesToTheServerThatOwnsIt() async {
        let storage = MemoryStorage()
        let queue = SyncQueue(storage: storage)
        let main = MockAPI()
        let other = MockAPI()
        await queue.enqueue(itemId: "mine", currentTime: 100, duration: 1000, isFinished: false)
        await queue.enqueue(itemId: "jf:book:x", currentTime: 200, duration: 1000, isFinished: false)

        await queue.flush { id in
            id.hasPrefix("jf:") ? ProgressTarget(key: "jf", client: other)
                                : ProgressTarget(key: "main", client: main)
        }

        #expect(main.written.map(\.itemId) == ["mine"], "der Haupt-Server bekommt NUR seine Kennung")
        #expect(other.written.map(\.itemId) == ["jf:book:x"], "das fremde Buch geht an seinen eigenen Server")
        #expect(storage.dict.isEmpty, "beide sind gelandet und damit aus der Warteschlange")
    }

    /// The second half, on its own: the stale check asks the same server
    /// as the write. Otherwise a foreign stand wins from a server that
    /// does not know the title at all, or it falls away entirely.
    @Test("the stale check asks the server that has the title")
    func theStaleCheckAsksTheOwningServer() async {
        let storage = MemoryStorage()
        let queue = SyncQueue(storage: storage)
        let main = MockAPI()
        let other = MockAPI()
        // The ids are chosen so that the one of the MAIN server comes first:
        // whoever fetches the stand once for all fetches its own. Otherwise
        // the case would hang on the order of a dictionary, and a
        // moody probe measures nothing.
        //
        // The wrong server claims the foreign book is almost finished. If
        // it is asked, the entry counts as stale and disappears; if
        // the right one is asked, it knows nothing of it and the position goes
        // out, where it belongs.
        main.progress["z-jf:book:x"] = BookProgress(fraction: 0.9, isFinished: false, lastUpdate: 0)
        await queue.enqueue(itemId: "a-mine", currentTime: 100, duration: 1000, isFinished: false)
        await queue.enqueue(itemId: "z-jf:book:x", currentTime: 100, duration: 1000, isFinished: false)

        await queue.flush { id in
            id.hasPrefix("z-jf:") ? ProgressTarget(key: "jf", client: other)
                                  : ProgressTarget(key: "main", client: main)
        }

        #expect(other.written.map(\.itemId) == ["z-jf:book:x"],
                "der eigene Server kennt keinen weiteren Stand, also geht die Position hinaus")
        #expect(main.written.map(\.itemId) == ["a-mine"], "und der andere bekommt nur seinen eigenen")
        #expect(storage.dict.isEmpty, "beide sind gelandet")
    }

    @Test("an id without an owner is kept, not offered to just anybody")
    func anEntryWithoutAnOwnerIsKept() async {
        let storage = MemoryStorage()
        let queue = SyncQueue(storage: storage)
        let main = MockAPI()
        await queue.enqueue(itemId: "niemand:1", currentTime: 100, duration: 1000, isFinished: false)

        await queue.flush { id in
            id.hasPrefix("niemand:") ? nil : ProgressTarget(key: "main", client: main)
        }

        #expect(main.written.isEmpty, "niemand besitzt die Kennung, also geht sie an niemanden")
        #expect(storage.dict["niemand:1"] != nil, "und sie bleibt, statt still verworfen zu werden")
    }

    @Test("a server that does not answer does not hold up the others")
    func oneUnreachableServerDoesNotHoldUpTheOthers() async {
        let storage = MemoryStorage()
        let queue = SyncQueue(storage: storage)
        let main = MockAPI()
        let other = MockAPI()
        other.fetchError = offlineError()
        await queue.enqueue(itemId: "mine", currentTime: 100, duration: 1000, isFinished: false)
        await queue.enqueue(itemId: "jf:book:x", currentTime: 200, duration: 1000, isFinished: false)

        await queue.flush { id in
            id.hasPrefix("jf:") ? ProgressTarget(key: "jf", client: other)
                                : ProgressTarget(key: "main", client: main)
        }

        #expect(main.written.map(\.itemId) == ["mine"], "der erreichbare Server bekommt seine Eintraege")
        #expect(storage.dict["jf:book:x"] != nil, "der unerreichbare behaelt seine, fuer den naechsten Lauf")
        #expect(storage.dict["mine"] == nil)
    }

    @Test func flushSendsAndRemovesPendingUpdate() async {
        let (queue, storage, api) = makeQueue()
        await queue.enqueue(itemId: "a", currentTime: 100, duration: 1000, isFinished: false)

        await queue.flush { _ in ProgressTarget(key: "fake", client: api) }

        #expect(api.written.count == 1)
        #expect(api.written[0].itemId == "a")
        #expect(api.written[0].currentTime == 100)
        #expect(storage.dict.isEmpty)
    }

    @Test("Server further ahead → discard the stale entry instead of writing")
    func flushDropsStaleUpdate() async {
        let (queue, storage, api) = makeQueue()
        await queue.enqueue(itemId: "a", currentTime: 100, duration: 1000, isFinished: false)
        api.progress = ["a": BookProgress(fraction: 0.5, isFinished: false, lastUpdate: 0)]

        await queue.flush { _ in ProgressTarget(key: "fake", client: api) }

        #expect(api.written.isEmpty)
        #expect(storage.dict.isEmpty)
    }

    @Test("a waiting 0 without a duration does not override the server's time, even with a stale fraction")
    func flushDropsAQueuedZeroWithoutDuration() async {
        let (queue, storage, api) = makeQueue()
        await queue.enqueue(itemId: "a", currentTime: 0, duration: 0, isFinished: false)
        api.progress = ["a": BookProgress(fraction: 0, isFinished: false, lastUpdate: 0, currentTime: 3000)]

        await queue.flush { _ in ProgressTarget(key: "fake", client: api) }

        #expect(api.written.isEmpty)
        #expect(storage.dict.isEmpty)
    }

    @Test("a server entry without a known position keeps the waiting stand in the queue")
    func flushHoldsAgainstAnUnknownServerPosition() async {
        let (queue, storage, api) = makeQueue()
        await queue.enqueue(itemId: "a", currentTime: 100, duration: 0, isFinished: false)
        api.progress = ["a": BookProgress(fraction: 0.9, isFinished: false, lastUpdate: 0)]

        await queue.flush { _ in ProgressTarget(key: "fake", client: api) }

        #expect(api.written.isEmpty)
        #expect(storage.dict["a"]?.currentTime == 100)
    }

    @Test("finished updates are also written when the server is further along")
    func flushKeepsFinishedUpdates() async {
        let (queue, _, api) = makeQueue()
        await queue.enqueue(itemId: "a", currentTime: 100, duration: 1000, isFinished: true)
        api.progress = ["a": BookProgress(fraction: 0.9, isFinished: false, lastUpdate: 0)]

        await queue.flush { _ in ProgressTarget(key: "fake", client: api) }

        #expect(api.written.count == 1)
        #expect(api.written[0].isFinished)
    }

    @Test("If the server stand fetch fails, nothing is written blindly")
    func flushAbortsWhenFetchFails() async {
        let (queue, storage, api) = makeQueue()
        await queue.enqueue(itemId: "a", currentTime: 100, duration: 1000, isFinished: false)
        api.fetchError = offlineError()

        await queue.flush { _ in ProgressTarget(key: "fake", client: api) }

        #expect(api.written.isEmpty)
        #expect(storage.dict.count == 1)
    }

    @Test("A failed write stays in the queue (next attempt)")
    func flushKeepsEntryOnWriteFailure() async {
        let (queue, storage, api) = makeQueue()
        await queue.enqueue(itemId: "a", currentTime: 100, duration: 1000, isFinished: false)
        api.updateError = offlineError()

        await queue.flush { _ in ProgressTarget(key: "fake", client: api) }

        #expect(storage.dict.count == 1)
    }

    @Test("Entries completed in parallel by the player are skipped")
    func flushSkipsEntriesRemovedMidFlight() async {
        let (queue, storage, api) = makeQueue()
        await queue.enqueue(itemId: "a", currentTime: 100, duration: 1000, isFinished: false)
        await queue.enqueue(itemId: "b", currentTime: 200, duration: 1000, isFinished: false)
        // At the first write the player removes the respective other entry.
        api.onUpdate = { written in
            let other = written == "a" ? "b" : "a"
            let seen = await queue.pendingUpdate(itemId: other)
            await queue.remove(itemId: other, ifStill: seen)
        }

        await queue.flush { _ in ProgressTarget(key: "fake", client: api) }

        // Only one written. The other was gone at the second pass.
        #expect(api.written.count == 1)
        #expect(storage.dict.isEmpty)
    }

    /// The player writes, and while its write is on the way the detail
    /// sheet queues "marked as heard" for the same book (its own write
    /// failed). The player's success may take only what it saw before.
    @Test("a decision queued during the player's write survives its success")
    func aDecisionQueuedDuringTheWriteSurvives() async {
        let (queue, storage, _) = makeQueue()
        // Nothing waited when the write started.
        let sawNothing = await queue.pendingUpdate(itemId: "book")
        await queue.enqueue(itemId: "book", currentTime: 900, duration: 900, isFinished: true)
        await queue.remove(itemId: "book", ifStill: sawNothing)
        #expect(storage.dict["book"]?.isFinished == true, "the decision queued meanwhile stays")

        // An older entry waited; the decision replaced it meanwhile.
        let older = await queue.pendingUpdate(itemId: "book")
        await queue.enqueue(itemId: "book", currentTime: 0, duration: 900, isFinished: false)
        await queue.remove(itemId: "book", ifStill: older)
        #expect(storage.dict["book"]?.isFinished == false, "the newer decision stays too")

        // What the writer saw and nothing replaced: that one leaves.
        let current = await queue.pendingUpdate(itemId: "book")
        await queue.remove(itemId: "book", ifStill: current)
        #expect(storage.dict["book"] == nil)
    }

    /// Both writes of the player hand over what they saw; an unconditional
    /// removal there was the way a decision got lost.
    @Test("the player removes only what it saw before its write", .needsTheSources)
    func thePlayerRemovesOnlyWhatItSaw() throws {
        let code = SyncContractFenceTests.stripped(try String(
            contentsOf: SourceTree.root.appendingPathComponent("Sources/ViewModels/PlayerViewModel+Sync.swift"),
            encoding: .utf8))
        // Any receiver: the queue is taken once per write as `queue`.
        let removals = code.components(separatedBy: ".remove(itemId:").count - 1
        let guarded = code.components(separatedBy: "queue.remove(itemId: item.id, ifStill: queuedBefore)").count - 1
        #expect(removals == 2 && guarded == 2, "removals \(removals), guarded by the snapshot \(guarded)")
        let snapshots = code.components(separatedBy: "let queuedBefore = await queue.pendingUpdate(itemId: item.id)").count - 1
        #expect(snapshots == 2, "each write notes what waited before it")
    }

    /// A newer position for the same title, queued while the older one is
    /// on its way to the server, stays: only the entry that was sent leaves.
    @Test("A stand of the same title newly queued during sending stays")
    func aNewerUpdateQueuedWhileSendingStays() async {
        let (queue, storage, api) = makeQueue()
        await queue.enqueue(itemId: "a", currentTime: 100, duration: 1000, isFinished: false)
        api.onUpdate = { _ in
            await queue.enqueue(itemId: "a", currentTime: 300, duration: 1000, isFinished: false)
        }

        await queue.flush { _ in ProgressTarget(key: "fake", client: api) }

        #expect(api.written.map(\.currentTime) == [100], "the precondition: the older one was sent")
        #expect(storage.dict["a"]?.currentTime == 300, "the newer position waits for the next flush")
    }

    /// A newer position queued while the flush asks the server is not
    /// overwritten by the older one the flush read: only the entry that was
    /// read may go out, and it is no longer the queued one.
    @Test("a stand newly queued during the fetch is not overwritten with the old one")
    func aNewerUpdateQueuedWhileFetchingIsNotOvertaken() async {
        let (queue, storage, api) = makeQueue()
        await queue.enqueue(itemId: "a", currentTime: 100, duration: 1000, isFinished: false)
        api.onFetch = {
            await queue.enqueue(itemId: "a", currentTime: 300, duration: 1000, isFinished: false)
        }

        await queue.flush { _ in ProgressTarget(key: "fake", client: api) }

        #expect(!api.written.map(\.currentTime).contains(100), "the older position overtook the newer one")
        #expect(storage.dict["a"]?.currentTime == 300, "the newer position waits for the next flush")
    }

    /// A send that failed keeps its entry and says why, in the shape the
    /// bookmark queue uses: a reason without an address or a token.
    @Test("a failed send stays in the queue and says why", .needsTheSources)
    func aFailedSendSaysWhy() throws {
        let code = SyncContractFenceTests.stripped(try String(
            contentsOf: SourceTree.root.appendingPathComponent("Sources/Networking/SyncQueue.swift"), encoding: .utf8))
        let send = try #require(code.range(of: "try await apiClient.updateProgress("))
        let after = code[send.upperBound...]
        let caught = try #require(after.range(of: "} catch {"))
        let block = after[caught.upperBound...].prefix(400)
        #expect(block.contains("FailureReason.of(error), privacy: .public"), "the failed send is silent")
        // The fetch of the server's state one step before is the same rule.
        let fetch = try #require(code.range(of: "try await target.client.fetchAllProgress()"))
        let fetchCaught = try #require(code[fetch.upperBound...].range(of: "} catch {"))
        let fetchBlock = code[fetchCaught.upperBound...].prefix(400)
        #expect(fetchBlock.contains("FailureReason.of(error), privacy: .public"), "the failed fetch is silent")
    }
}
#endif
