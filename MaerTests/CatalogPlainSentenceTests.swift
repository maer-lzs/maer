// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// A page says a plain sentence, never a measured code or a step name; the
/// code and the step go to the log line.
struct CatalogPlainSentenceTests {
    private func code(_ path: String) throws -> String {
        SyncContractFenceTests.stripped(try String(contentsOf: SourceTree.root.appendingPathComponent(path), encoding: .utf8))
    }

    /// Every catalog page reaches the sentence through the one door that
    /// also writes the log line; nobody asks the bare sentence beside it.
    @Test("jede Katalog-Seite nimmt den Satz ueber die eine Tuer, die auch die Logzeile schreibt", .needsTheSources)
    func everyPageGoesThroughTheDoor() throws {
        var beside: [String] = []
        var doors = 0
        for (name, text) in ProjectFileIntegrityTests.sourceTexts(in: ["Sources"]) {
            let code = SyncContractFenceTests.stripped(text)
            if name != "FreeCatalog.swift", name != "CatalogPageFailure.swift", code.contains("FreeCatalog.failureReason(") {
                beside.append(name)
            }
            doors += code.components(separatedBy: "CatalogPageFailure.sentence(for:").count - 1
        }
        #expect(beside.isEmpty, "a page asks the sentence without the log line: \(beside.sorted())")
        #expect(doors == 10, "the pages that show a catalog failure are not the ten measured: \(doors)")
        let door = try code("Sources/ViewModels/CatalogPageFailure.swift")
        #expect(door.contains("FreeCatalog.failureReason(error)") && door.contains("FreeCatalog.logReason(error)"),
                "the door does not give the sentence and log the measured reason")
        // The cell that only logs asks the log reason.
        let cell = try code("Sources/Views/CatalogTrackCell.swift")
        #expect(cell.contains("FreeCatalog.logReason(error)"), "the cell logs the page sentence")
    }

    @Test("die Tuer gibt den Satz der Seite und schweigt bei einem Abbruch")
    func theDoorGivesTheSentence() {
        let error = APIError.http(429, "slow down")
        #expect(CatalogPageFailure.sentence(for: error, at: "witness") == FreeCatalog.failureReason(error))
        #expect(CatalogPageFailure.sentence(for: CancellationError(), at: "witness") == nil)
    }

    /// The server branch of a subscribe hands back the sentence alone; the
    /// step and the measured reason are in its log lines.
    @Test("das Abo auf dem Server gibt nur den Satz zurueck, Schritt und Grund stehen in der Logzeile", .needsTheSources)
    func theServerSubscribeSaysASentence() throws {
        let provider = try code("Sources/Providers/ABSPodcastProvider.swift")
        let start = try #require(provider.range(of: "func subscribeOnServer("), "the server subscribe is gone")
        let end = try #require(provider.range(of: "func updateShowCover(", range: start.upperBound..<provider.endIndex))
        let body = String(provider[start.upperBound..<end.lowerBound])
        #expect(!body.contains("return \""), "a step or a raw text reaches the person")
        for step in ["step=libraries", "step=podcasts/feed", "step=libraries/id", "step=folders", "step=POST podcasts"] {
            #expect(body.contains(step), "the log line does not name the step \(step)")
        }
    }
}
#endif
