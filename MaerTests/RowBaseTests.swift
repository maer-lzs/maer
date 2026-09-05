// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
@testable import Maer

/// The one rule every row store follows: what the rows are known to hold
/// decides the write, and only a landed write moves that knowledge.
struct RowBaseTests {
    @Test("Bekannt = Diff, frisch = ganz, unbekannt = nur Upserts")
    func planFollowsTheBase() {
        #expect(RowBase<[String: Int]>.known(["a": 1]).plan == .diff)
        #expect(RowBase<[String: Int]>.fresh.plan == .whole)
        #expect(RowBase<[String: Int]>.unknown.plan == .upsertOnly)
        #expect(RowBase<[String: Int]>.known(["a": 1]).knownValue == ["a": 1])
        #expect(RowBase<[String: Int]>.unknown.knownValue == nil)
    }

    @Test("Ein gelandeter Schrieb rueckt die Basis vor, ein gescheiterter laesst sie stehen")
    func onlyALandedWriteMovesTheBase() {
        let base = RowBase<[String: Int]>.known(["a": 1])
        #expect(base.landed(["a": 2], success: true).knownValue == ["a": 2])
        #expect(base.landed(["a": 2], success: false).knownValue == ["a": 1])
        // Unknown rows stay unknown after a failed first write; a landed
        // upsert makes the snapshot the known state.
        let unknown = RowBase<[String: Int]>.unknown
        #expect(unknown.landed(["a": 2], success: false).plan == .upsertOnly)
        #expect(unknown.landed(["a": 2], success: true).plan == .diff)
    }

    /// The diff against nothing upserts everything and removes nothing:
    /// that is why unknown rows are safe under the first write.
    @Test("Der Diff gegen nichts entfernt nichts")
    func diffAgainstNothingRemovesNothing() {
        let diff = KeyedRowDiff.compute(previous: [:], current: ["a": 1, "b": 2])
        #expect(diff.upserted == ["a": 1, "b": 2])
        #expect(diff.removed.isEmpty)
    }
}
#endif
