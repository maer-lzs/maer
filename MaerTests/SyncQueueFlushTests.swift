// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// In-Memory-Storage für Tests (Klasse: Zustand nach dem Flush inspizierbar).
private final class MemoryStorage: SyncQueueStorage {
    var dict: [String: SyncQueue.PendingUpdate] = [:]
    func load() -> [String: SyncQueue.PendingUpdate] { dict }
    func save(_ pending: [String: SyncQueue.PendingUpdate]) { dict = pending }
    func awaitPendingWrites() async {}
}

@MainActor
private final class MockAPI: ProgressSyncAPI {
    var progress: [String: BookProgress] = [:]
    var fetchError: Error?
    var updateError: Error?
    var written: [(itemId: String, currentTime: Double, isFinished: Bool)] = []
    /// Hook, um während des Flushs Nebenläufigkeit zu simulieren
    /// (z. B. aktiver Player entfernt einen Queue-Eintrag).
    var onUpdate: ((String) async -> Void)?

    func fetchAllProgress() async throws -> [String: BookProgress] {
        if let fetchError { throw fetchError }
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

/// Tests für den Flush-Ablauf der SyncQueue (Regeln selbst: SyncRulesTests).
@MainActor
struct SyncQueueFlushTests {

    private func makeQueue() -> (SyncQueue, MemoryStorage, MockAPI) {
        let storage = MemoryStorage()
        return (SyncQueue(storage: storage), storage, MockAPI())
    }

    // MARK: - Jeder Eintrag zu SEINEM Server

    /// Die Warteschlange haelt einen Eintrag je TITEL, und ein Titel traegt
    /// seine Quelle in der Kennung. Sie nahm trotzdem EINEN Klienten fuer
    /// alles darin, und beide Rufer gaben den Haupt-Anbieter. Seit das Regal
    /// Zweitquellen mischt, landet damit eine `jf:`-Position beim
    /// Bibliotheks-Server.
    ///
    /// Zwei Haelften, und die zweite ist die leisere: der Schrieb ging an den
    /// falschen Server, UND die Pruefung „der Server gewinnt" fragte
    /// denselben falschen. Fuer ein fremdes Buch steht dort nichts, ein
    /// fehlender Eintrag liest sich als „kein Serverstand", und der Schutz
    /// entfiel still.
    @Test("jeder Eintrag geht an den Server, dem seine Kennung gehoert")
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

    /// Die zweite Haelfte, einzeln: die Stale-Pruefung fragt denselben Server
    /// wie der Schrieb. Sonst gewinnt ein fremder Stand von einem Server, der
    /// den Titel gar nicht kennt, oder er entfaellt ganz.
    @Test("die Stale-Pruefung fragt den Server, der den Titel hat")
    func theStaleCheckAsksTheOwningServer() async {
        let storage = MemoryStorage()
        let queue = SyncQueue(storage: storage)
        let main = MockAPI()
        let other = MockAPI()
        // Die Kennungen sind so gewaehlt, dass die des HAUPT-Servers zuerst
        // drankommt: wer den Stand einmal fuer alle holt, holt also seinen.
        // Sonst haenge der Fall an der Reihenfolge eines Woerterbuchs, und
        // eine launische Probe misst nichts.
        //
        // Der falsche Server behauptet, das fremde Buch sei fast durch. Wird
        // er gefragt, gilt der Eintrag als veraltet und verschwindet; wird
        // der richtige gefragt, weiss der nichts davon und die Position geht
        // hinaus, wohin sie gehoert.
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

    @Test("eine Kennung ohne Besitzer wird aufgehoben, nicht irgendwem angeboten")
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

    @Test("ein Server, der nicht antwortet, haelt die anderen nicht auf")
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

    @Test("Server weiter voraus → veralteten Eintrag verwerfen statt schreiben")
    func flushDropsStaleUpdate() async {
        let (queue, storage, api) = makeQueue()
        await queue.enqueue(itemId: "a", currentTime: 100, duration: 1000, isFinished: false)
        api.progress = ["a": BookProgress(fraction: 0.5, isFinished: false, lastUpdate: 0)]

        await queue.flush { _ in ProgressTarget(key: "fake", client: api) }

        #expect(api.written.isEmpty)
        #expect(storage.dict.isEmpty)
    }

    @Test("finished-Updates werden auch bei weiter fortgeschrittenem Server geschrieben")
    func flushKeepsFinishedUpdates() async {
        let (queue, _, api) = makeQueue()
        await queue.enqueue(itemId: "a", currentTime: 100, duration: 1000, isFinished: true)
        api.progress = ["a": BookProgress(fraction: 0.9, isFinished: false, lastUpdate: 0)]

        await queue.flush { _ in ProgressTarget(key: "fake", client: api) }

        #expect(api.written.count == 1)
        #expect(api.written[0].isFinished)
    }

    @Test("Scheitert der Serverstand-Abruf, wird NICHT blind geschrieben")
    func flushAbortsWhenFetchFails() async {
        let (queue, storage, api) = makeQueue()
        await queue.enqueue(itemId: "a", currentTime: 100, duration: 1000, isFinished: false)
        api.fetchError = offlineError()

        await queue.flush { _ in ProgressTarget(key: "fake", client: api) }

        #expect(api.written.isEmpty)
        #expect(storage.dict.count == 1)
    }

    @Test("Fehlgeschlagener Write bleibt in der Queue (nächster Versuch)")
    func flushKeepsEntryOnWriteFailure() async {
        let (queue, storage, api) = makeQueue()
        await queue.enqueue(itemId: "a", currentTime: 100, duration: 1000, isFinished: false)
        api.updateError = offlineError()

        await queue.flush { _ in ProgressTarget(key: "fake", client: api) }

        #expect(storage.dict.count == 1)
    }

    @Test("Vom Player parallel erledigte Einträge werden übersprungen")
    func flushSkipsEntriesRemovedMidFlight() async {
        let (queue, storage, api) = makeQueue()
        await queue.enqueue(itemId: "a", currentTime: 100, duration: 1000, isFinished: false)
        await queue.enqueue(itemId: "b", currentTime: 200, duration: 1000, isFinished: false)
        // Beim ersten Write entfernt der Player den jeweils anderen Eintrag.
        api.onUpdate = { written in
            let other = written == "a" ? "b" : "a"
            await queue.remove(itemId: other)
        }

        await queue.flush { _ in ProgressTarget(key: "fake", client: api) }

        // Nur einer geschrieben. Der andere war beim zweiten Durchgang weg.
        #expect(api.written.count == 1)
        #expect(storage.dict.isEmpty)
    }
}
#endif
