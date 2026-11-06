// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// A failed lookup is not asked again at once, and never kept as an answer.
struct FetchHoldbackTests {
    /// A clock the witness moves by hand. Unchecked because one lock guards
    /// the moment.
    nonisolated final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var value = Date(timeIntervalSince1970: 1_000_000)
        var now: Date { lock.withLock { value } }
        func advance(_ seconds: TimeInterval) { lock.withLock { value += seconds } }
    }

    /// Unchecked because one lock guards the count.
    nonisolated final class Count: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        func add() { lock.withLock { value += 1 } }
        var count: Int { lock.withLock { value } }
    }

    @Test("ein Fehlschlag haelt zurueck, ein Abbruch und ein weg nicht")
    func whatStartsAHoldback() {
        #expect(FetchHoldback.starts(after: URLError(.timedOut)))
        #expect(FetchHoldback.starts(after: APIError.http(503, "")))
        #expect(FetchHoldback.starts(after: DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "x"))),
                "eine Antwort, die nicht decodiert, ist ein Fehlschlag")
        #expect(!FetchHoldback.starts(after: CancellationError()), "ein Abbruch ist kein Ereignis")
        #expect(!FetchHoldback.starts(after: URLError(.cancelled)))
        #expect(!FetchHoldback.starts(after: APIError.http(404, "")), "weg ist ein Befund, kein Fehlschlag")
    }

    @Test("zehn Minuten nach dem Fehlschlag darf wieder gefragt werden, vorher nicht")
    func tenMinutes() {
        let failed = Date(timeIntervalSince1970: 0)
        #expect(FetchHoldback.seconds == 600)
        #expect(FetchHoldback.mayAsk(failedAt: nil, now: failed))
        #expect(!FetchHoldback.mayAsk(failedAt: failed, now: failed.addingTimeInterval(599)))
        #expect(FetchHoldback.mayAsk(failedAt: failed, now: failed.addingTimeInterval(600)))
    }

    @Test("der Flug fragt nach einem Fehlschlag erst nach dem Rueckhalt wieder")
    func theFlightWaitsOutTheHoldback() async throws {
        let clock = Clock()
        let held = Count()
        let runs = Count()
        let flights = CoalescedFlights<Int>(capacity: FlightCapacity(entries: 8, bytes: 100), holdsBack: true,
                                            now: { clock.now }, onHeldBack: { _ in held.add() })
        await #expect(throws: URLError.self) {
            try await LookupOccasion.automatic {
                try await flights.value(for: "k") { runs.add(); throw URLError(.timedOut) }
            }
        }
        await #expect(throws: FetchHeldBack.self) {
            try await LookupOccasion.automatic {
                try await flights.value(for: "k") { runs.add(); return (1, 1) }
            }
        }
        #expect(runs.count == 1 && held.count == 1, "im Rueckhalt kein Netzabruf, eine Zaehlzeile")
        clock.advance(FetchHoldback.seconds)
        #expect(try await LookupOccasion.automatic {
            try await flights.value(for: "k") { runs.add(); return (2, 1) }
        } == 2)
        #expect(runs.count == 2, "nach dem Rueckhalt fragt die naechste Frage")
    }

    /// A tap on "try again", an opened detail, a playback start: deliberate,
    /// the default. It reaches the network inside the holdback, and when it
    /// succeeds the holdback of the id is gone.
    @Test("eine bewusste Frage erreicht im Rueckhalt das Netz und beendet ihn mit einem Erfolg")
    func aDeliberateQuestionAlwaysAsks() async throws {
        let clock = Clock()
        let held = Count()
        let runs = Count()
        let flights = CoalescedFlights<Int>(capacity: .none, holdsBack: true,
                                            now: { clock.now }, onHeldBack: { _ in held.add() })
        _ = try? await LookupOccasion.automatic {
            try await flights.value(for: "k") { runs.add(); throw URLError(.timedOut) }
        }
        #expect(try await flights.value(for: "k") { runs.add(); return (1, 1) } == 1,
                "Wiederholen per Tipp fragt, auch im Rueckhalt")
        #expect(runs.count == 2 && held.count == 0)
        #expect(try await LookupOccasion.automatic {
            try await flights.value(for: "k") { runs.add(); return (2, 1) }
        } == 2, "nach dem bewussten Erfolg fragt auch die Zelle wieder")
        #expect(runs.count == 3)
    }

    @Test("ein Zurueckhalten erreicht keinen Satz, den ein Mensch liest")
    func aHoldbackIsNeverSaid() {
        #expect(FreeCatalog.failureReason(FetchHeldBack(), online: true) == nil)
        #expect(FreeCatalog.failureReason(URLError(.timedOut), online: true) != nil, "ein echter Fehlschlag bleibt benannt")
    }

    /// The automatic questions, measured: a cell, a queue row and a featured
    /// card that appear, a tile's runtime, the background healing of a
    /// playlist. Every other catalogue question is deliberate.
    nonisolated static let automaticSites: [String: (count: Int, reason: String)] = [
        "CatalogTrackCell.swift": (1, "a catalogue cell resolves its name when it appears"),
        "PlayQueueView.swift": (1, "a queue row resolves its name when it appears"),
        "BookFeaturedCard.swift": (1, "the featured card loads its chapters when it appears"),
        "ArchiveRuntimeService.swift": (1, "a tile asks for its runtime when it appears"),
        "MaerPlaylists.swift": (1, "a playlist heals missing titles in the background"),
    ]

    @Test("die automatische Marke steht nur an den benannten Stellen", .needsTheSources)
    func theAutomaticMarkStandsOnlyWhereNamed() throws {
        var found: [String: Int] = [:]
        for file in ProjectFileIntegrityTests.sourceFiles() where file.lastPathComponent != "CoalescedFlights.swift" {
            let text = try String(contentsOf: file, encoding: .utf8)
            let hits = text.components(separatedBy: "LookupOccasion.automatic").count - 1
            if hits > 0 { found[file.lastPathComponent] = hits }
        }
        #expect(found == Self.automaticSites.mapValues(\.count), "automatische Fragen: \(found.sorted { $0.key < $1.key })")
    }

    /// Only an automatic question waits out a holdback, so the question
    /// after the cancellation is automatic too: a deliberate one would ask
    /// the network even inside a holdback and prove nothing.
    @Test("ein Abbruch haelt nicht zurueck, und ohne Rueckhalt fragt der Flug sofort wieder")
    func aCancellationDoesNotHoldBack() async throws {
        let clock = Clock()
        let held = Count()
        let holding = CoalescedFlights<Int>(capacity: .none, holdsBack: true,
                                            now: { clock.now }, onHeldBack: { _ in held.add() })
        _ = try? await LookupOccasion.automatic {
            try await holding.value(for: "k") { throw CancellationError() }
        }
        #expect(try await LookupOccasion.automatic {
            try await holding.value(for: "k") { (1, 1) }
        } == 1, "die automatische Frage nach einem Abbruch fragt sofort")
        #expect(held.count == 0)
        let plain = CoalescedFlights<Int>(capacity: .none, now: { clock.now })
        _ = try? await plain.value(for: "k") { throw URLError(.timedOut) }
        #expect(try await plain.value(for: "k") { (2, 1) } == 2, "ohne Rueckhalt wie in F1a")
    }

    @Test("vergessen raeumt die behaltene Antwort, die naechste Frage fragt das Netz")
    func forgetDropsTheKeptAnswer() async throws {
        let runs = Count()
        let flights = CoalescedFlights<Int>(capacity: FlightCapacity(entries: 8, bytes: 100))
        _ = try await flights.value(for: "k") { runs.add(); return (1, 1) }
        _ = try await flights.value(for: "k") { runs.add(); return (1, 1) }
        #expect(runs.count == 1)
        await flights.forget("k")
        #expect(await flights.storedCount == 0)
        _ = try await flights.value(for: "k") { runs.add(); return (1, 1) }
        #expect(runs.count == 2)
    }

    /// The player forgets a catalogue answer where playback visibly failed:
    /// both places that show the track failure hint after the retry.
    @Test("ein sichtbar gescheitertes Abspielen vergisst die Katalog-Antwort", .needsTheSources)
    func aFailedPlaybackForgetsTheAnswer() throws {
        let text = try String(contentsOf: SourceTree.root.appendingPathComponent(
            "Sources/ViewModels/PlayerViewModel.swift"), encoding: .utf8)
        let body = try #require(functionBody(of: "private func handleTrackFailure(", in: text))
        #expect(body.components(separatedBy: "showSourceHint(.trackFailed)").count - 1 == 2)
        #expect(body.components(separatedBy: "forgetCatalogAnswer()").count - 1 == 2,
                "jede sichtbare Fehlstelle vergisst die Antwort")
        #expect(text.contains("ArchiveOrgClient.forgetMetadata(identifier: identifier)"))
    }
}
#endif
