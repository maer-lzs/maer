// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// A pause that comes while a finished mark holds the guard of the writes is
/// written once after the mark, unless the mark set the title finished.
struct MarkFollowUpTests {
    @Test("a pause during the mark runs once afterwards, unless the mark finished writing")
    func aPauseDuringAMarkRunsAfterIt() {
        #expect(MarkFollowUp.origin(asked: "pause", markedFinished: false) == "pause", "a pause is written after the mark")
        #expect(MarkFollowUp.origin(asked: "pause", markedFinished: true) == nil,
                "the finished mark is the newer stand, the paused position would undo it")
        #expect(MarkFollowUp.origin(asked: String?.none, markedFinished: false) == nil, "nothing asked, nothing runs")
    }

    @Test("both marks run under the one lock that afterwards runs the remembered write", .needsTheSources)
    func bothMarksRunUnderTheOneGuard() throws {
        let code = SyncContractFenceTests.stripped(try String(
            contentsOf: SourceTree.root.appendingPathComponent("Sources/ViewModels/PlayerViewModel+Sync.swift"), encoding: .utf8))
        #expect(code.components(separatedBy: "await underTheMarkGuard {").count - 1 == 2,
                "a mark runs past the guard that writes the noted pause after it")
        #expect(code.components(separatedBy: "syncInFlight = true").count - 1 == 2,
                "the guard is taken somewhere else than in the sync round and the mark guard")
        #expect(code.contains("MarkFollowUp.origin(asked:"), "the guard no longer asks the rule")
    }
}
#endif
