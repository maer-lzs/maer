// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import ABSPlayer

/// In-Memory-Storage für Tests (Klasse: Zustand nach dem Flush inspizierbar).
private final class MemoryStorage: SyncQueueStorage {
    var dict: [String: SyncQueue.PendingUpdate] = [:]
    func load() -> [String: SyncQueue.PendingUpdate] { dict }
    func save(_ pending: [String: SyncQueue.PendingUpdate]) { dict = pending }
}

@MainActor
private final class MockAPI: ProgressSyncAPI {
    var progress: [String: BookProgress] = [:]
    var fetchError: Error?
    var updateError: Error?
    var written: [(itemId: String, currentTime: Double, isFinished: Bool)] = []
    /// Hook, um während des Flushs Nebenläufigkeit zu simulieren
    /// (z. B. aktiver Player entfernt einen Queue-Eintrag).
    var onUpdate: ((String) -> Void)?

    func fetchAllProgress() async throws -> [String: BookProgress] {
        if let fetchError { throw fetchError }
        return progress
    }

    func updateProgress(itemId: String, currentTime: Double, duration: Double, isFinished: Bool) async throws {
        if let updateError { throw updateError }
        onUpdate?(itemId)
        written.append((itemId, currentTime, isFinished))
    }
}

private func offlineError() -> Error {
    NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet)
}

/// Tests für den Flush-Ablauf der SyncQueue (Regeln selbst: SyncRulesTests).
@MainActor
struct SyncQueueFlushTests {

    private func makeQueue() -> (SyncQueue, MemoryStorage, MockAPI) {
        let storage = MemoryStorage()
        return (SyncQueue(storage: storage), storage, MockAPI())
    }

    @Test func flushSendsAndRemovesPendingUpdate() async {
        let (queue, storage, api) = makeQueue()
        queue.enqueue(itemId: "a", currentTime: 100, duration: 1000, isFinished: false)

        await queue.flush(apiClient: api)

        #expect(api.written.count == 1)
        #expect(api.written[0].itemId == "a")
        #expect(api.written[0].currentTime == 100)
        #expect(storage.dict.isEmpty)
    }

    @Test("Server weiter voraus → veralteten Eintrag verwerfen statt schreiben")
    func flushDropsStaleUpdate() async {
        let (queue, storage, api) = makeQueue()
        queue.enqueue(itemId: "a", currentTime: 100, duration: 1000, isFinished: false)
        api.progress = ["a": BookProgress(fraction: 0.5, isFinished: false, lastUpdate: 0)]

        await queue.flush(apiClient: api)

        #expect(api.written.isEmpty)
        #expect(storage.dict.isEmpty)
    }

    @Test("finished-Updates werden auch bei weiter fortgeschrittenem Server geschrieben")
    func flushKeepsFinishedUpdates() async {
        let (queue, _, api) = makeQueue()
        queue.enqueue(itemId: "a", currentTime: 100, duration: 1000, isFinished: true)
        api.progress = ["a": BookProgress(fraction: 0.9, isFinished: false, lastUpdate: 0)]

        await queue.flush(apiClient: api)

        #expect(api.written.count == 1)
        #expect(api.written[0].isFinished)
    }

    @Test("Scheitert der Serverstand-Abruf, wird NICHT blind geschrieben")
    func flushAbortsWhenFetchFails() async {
        let (queue, storage, api) = makeQueue()
        queue.enqueue(itemId: "a", currentTime: 100, duration: 1000, isFinished: false)
        api.fetchError = offlineError()

        await queue.flush(apiClient: api)

        #expect(api.written.isEmpty)
        #expect(storage.dict.count == 1)
    }

    @Test("Fehlgeschlagener Write bleibt in der Queue (nächster Versuch)")
    func flushKeepsEntryOnWriteFailure() async {
        let (queue, storage, api) = makeQueue()
        queue.enqueue(itemId: "a", currentTime: 100, duration: 1000, isFinished: false)
        api.updateError = offlineError()

        await queue.flush(apiClient: api)

        #expect(storage.dict.count == 1)
    }

    @Test("Vom Player parallel erledigte Einträge werden übersprungen")
    func flushSkipsEntriesRemovedMidFlight() async {
        let (queue, storage, api) = makeQueue()
        queue.enqueue(itemId: "a", currentTime: 100, duration: 1000, isFinished: false)
        queue.enqueue(itemId: "b", currentTime: 200, duration: 1000, isFinished: false)
        // Beim ersten Write entfernt der Player den jeweils anderen Eintrag.
        api.onUpdate = { written in
            let other = written == "a" ? "b" : "a"
            queue.remove(itemId: other)
        }

        await queue.flush(apiClient: api)

        // Nur einer geschrieben — der andere war beim zweiten Durchgang weg.
        #expect(api.written.count == 1)
        #expect(storage.dict.isEmpty)
    }
}
#endif
