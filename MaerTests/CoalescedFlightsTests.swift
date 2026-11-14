// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// The flights of the catalogue lookups, without the network: a stand-in
/// work counts how often it ran and waits for the witness to let it land.
struct CoalescedFlightsTests {
    /// Counts the work and holds it until `open()`.
    actor Stand {
        private(set) var runs = 0
        private var held: [CheckedContinuation<Void, Never>] = []
        private var isOpen = false
        func work() async {
            runs += 1
            if isOpen { return }
            await withCheckedContinuation { held.append($0) }
        }
        func open() {
            isOpen = true
            held.forEach { $0.resume() }
            held = []
        }
    }

    /// Counts the callers that left. Unchecked because one lock guards the
    /// count.
    nonisolated final class Left: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        func add() { lock.withLock { value += 1 } }
        var count: Int { lock.withLock { value } }
    }

    struct Failed: Error {}

    /// Lets queued work reach its wait before the witness looks.
    static func settle() async {
        for _ in 0..<20 { await Task.yield() }
        try? await Task.sleep(for: .milliseconds(20))
    }

    @Test("six simultaneous callers yield one fetch, and all get the same answer")
    func sixCallersOneFetch() async throws {
        let flights = CoalescedFlights<Int>(capacity: .none)
        let stand = Stand()
        let answers = await withTaskGroup(of: Int?.self) { group in
            for _ in 0..<6 {
                group.addTask { try? await flights.value(for: "k") { await stand.work(); return (42, 1) } }
            }
            await Self.settle()
            await stand.open()
            var out: [Int?] = []
            for await answer in group { out.append(answer) }
            return out
        }
        #expect(await stand.runs == 1, "ein Flug je Kennung")
        #expect(answers == Array(repeating: 42, count: 6))
    }

    @Test("a caller who left ends only its wait; the fetch runs to the end, the second gets the answer")
    func aLeavingCallerOnlyStopsItsWait() async throws {
        let left = Left()
        let flights = CoalescedFlights<Int>(capacity: .none, onLeft: { _ in left.add() })
        let stand = Stand()
        let first = Task { try await flights.value(for: "k") { await stand.work(); return (7, 1) } }
        await Self.settle()
        let second = Task { try await flights.value(for: "k") { await stand.work(); return (7, 1) } }
        await Self.settle()
        first.cancel()
        await #expect(throws: CancellationError.self) { try await first.value }
        #expect(left.count == 1, "der gegangene Anrufer wird einmal gezaehlt")
        await stand.open()
        #expect(try await second.value == 7, "der Abruf lief weiter und traf den zweiten")
        #expect(await stand.runs == 1)
    }

    @Test("after the end the key is free, and a failure is not kept")
    func afterTheEndTheKeyIsFree() async throws {
        let flights = CoalescedFlights<Int>(capacity: FlightCapacity(entries: 8, bytes: 100))
        let stand = Stand()
        await stand.open()
        await #expect(throws: Failed.self) {
            try await flights.value(for: "k") { await stand.work(); throw Failed() }
        }
        #expect(await flights.storedCount == 0, "ein Fehlschlag ist kein Wissen")
        #expect(try await flights.value(for: "k") { await stand.work(); return (3, 1) } == 3)
        #expect(await stand.runs == 2, "nach dem Fehlschlag fragt die naechste Frage neu")
    }

    @Test("the second question after the end comes from the store, without a fetch")
    func theSecondQuestionAfterTheEndComesFromTheStore() async throws {
        let flights = CoalescedFlights<Int>(capacity: FlightCapacity(entries: 8, bytes: 100))
        let stand = Stand()
        await stand.open()
        #expect(try await flights.value(for: "k") { await stand.work(); return (5, 10) } == 5)
        #expect(try await flights.value(for: "k") { await stand.work(); return (6, 10) } == 5)
        #expect(await stand.runs == 1, "die Ablage antwortet ohne Abruf")
    }

    @Test("an answer whose caller already left still lands in the store")
    func anAnswerWhoseCallerLeftIsStillKept() async throws {
        let flights = CoalescedFlights<Int>(capacity: FlightCapacity(entries: 8, bytes: 100))
        let stand = Stand()
        let first = Task { try await flights.value(for: "k") { await stand.work(); return (9, 1) } }
        await Self.settle()
        first.cancel()
        _ = try? await first.value
        await stand.open()
        await Self.settle()
        #expect(await flights.storedCount == 1)
        #expect(try await flights.value(for: "k") { await stand.work(); return (0, 1) } == 9)
        #expect(await stand.runs == 1, "die wieder erscheinende Zelle fragt nicht neu")
    }

    @Test("the store is capped, by count and by size, the oldest goes first")
    func theStoreIsCapped() async throws {
        let flights = CoalescedFlights<Int>(capacity: FlightCapacity(entries: 2, bytes: 100))
        for (index, key) in ["a", "b", "c"].enumerated() {
            _ = try await flights.value(for: key) { (index, 10) }
        }
        #expect(await flights.storedCount == 2, "hoechstens zwei Eintraege")
        #expect(try await flights.value(for: "a") { (99, 10) } == 99, "der aelteste ist gegangen")
        let sized = CoalescedFlights<Int>(capacity: FlightCapacity(entries: 8, bytes: 25))
        _ = try await sized.value(for: "a") { (1, 10) }
        _ = try await sized.value(for: "b") { (2, 10) }
        _ = try await sized.value(for: "c") { (3, 10) }
        #expect(await sized.storedCount == 2, "hoechstens 25 Bytes")
        _ = try await sized.value(for: "big") { (4, 30) }
        #expect(await sized.storedCount == 2, "eine Antwort ueber dem Deckel wird nicht behalten")
    }

    /// Every metadata request of archive.org goes through the one fetch, and
    /// that fetch only runs inside a flight. Named exception: `liveness`,
    /// which must stay fresh (a withdrawn item) and never reads the store.
    @Test("every metadata fetch runs through the flight, named exception liveness", .needsTheSources)
    func everyMetadataFetchFlies() throws {
        let text = try String(contentsOf: SourceTree.root.appendingPathComponent(
            "Sources/Networking/FreeCatalogClients.swift"), encoding: .utf8)
        var found: [String] = []
        for file in ProjectFileIntegrityTests.sourceFiles() {
            let source = try String(contentsOf: file, encoding: .utf8)
            let hits = source.components(separatedBy: "archive.org/metadata/").count - 1
            if hits > 0 { found.append("\(file.lastPathComponent):\(hits)") }
        }
        #expect(found.sorted() == ["FreeCatalogClients.swift:2"],
                "Metadaten-Adressen ausserhalb der einen Stelle: \(found)")
        let fetch = try #require(functionBody(of: "private static func fetchMetadata(", in: text))
        #expect(fetch.contains("archive.org/metadata/"))
        let live = try #require(functionBody(of: "static func liveness(identifier: String)", in: text))
        #expect(live.contains("archive.org/metadata/"), "die benannte Ausnahme")
        #expect(!live.contains("Flights"), "liveness liest nie die Ablage")
        let full = try #require(functionBody(of: "static func metadata(identifier: String)", in: text))
        let only = try #require(functionBody(of: "static func metadataOnly(identifier: String)", in: text))
        #expect(full.contains("metadataFlights.value(for: identifier)") && full.contains("fetchMetadata("))
        #expect(only.contains("metadataOnlyFlights.value(for: identifier)") && only.contains("fetchMetadata("))
        #expect(text.components(separatedBy: "try await fetchMetadata(").count - 1 == 2,
                "ein dritter Aufruf der einen Abfrage laeuft am Flug vorbei")
    }
}
#endif
