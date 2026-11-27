// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// A gpodder occasion during a running round is kept and runs once after
/// it, never dropped and never lost at the round's end.
struct GPodderRoundGateTests {
    @Test("an occasion during a round is noted, and the end runs once again; a quiet round runs no second")
    func noteAndRunAgain() {
        var gate = GPodderRoundGate()
        let first = gate.begin(), beside = gate.begin(), again = gate.begin(), runsAgain = gate.end()
        let next = gate.begin(), quietEnd = gate.end(), open = gate.begin()
        #expect(first)
        #expect(!beside, "a second round started beside the first")
        #expect(!again)
        #expect(runsAgain, "the occasion during the round was lost")
        #expect(next)
        #expect(!quietEnd, "a quiet round asked for another")
        #expect(open, "the gate stayed shut after a round")
    }

    @Test("Fence: the round asks the gate at its start and reads it in the same step as it ends", .needsTheSources)
    func roundUsesTheGate() throws {
        let sync = SyncContractFenceTests.stripped(try String(contentsOf: SourceTree.root.appendingPathComponent("Sources/Networking/GPodderSync.swift"), encoding: .utf8))
        let start = try #require(sync.range(of: "func reconcile() async -> Report {"))
        let head = sync[start.upperBound...].prefix(500)
        #expect(head.contains("guard roundGate.begin() else {"))
        #expect(!head.contains("guard !isRunning else"))
        #expect(sync.contains("if roundGate.end() {"))
    }
}
#endif
