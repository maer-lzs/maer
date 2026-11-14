// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// The one rule every row store follows: what the rows are known to hold
/// decides the write, and only a landed write moves that knowledge.
struct RowBaseTests {
    @Test("Known = diff, fresh and unread = only upserts, unknown with something read = remove what was read (only the move replaces everything)")
    func planFollowsTheBase() {
        #expect(RowBase<[String: Int]>.known(["a": 1]).plan == .diff)
        #expect(RowBase<[String: Int]>.fresh.plan == .upsertOnly)
        #expect(RowBase<[String: Int]>.unknown(seen: nil).plan == .upsertOnly)
        #expect(RowBase<[String: Int]>.unknown(seen: ["a": 1]).plan == .removeSeen)
        #expect(RowBase<[String: Int]>.known(["a": 1]).knownValue == ["a": 1])
        #expect(RowBase<[String: Int]>.unknown(seen: ["a": 1]).knownValue == nil)
    }

    /// The plan reads the same for a fresh table and one nobody could read;
    /// the start line names the base itself.
    @Test("The start line names the base: fresh, known, unknown with something read and wholly unread are four names")
    func theBasisNamesWhatThePlanCannot() {
        #expect(RowBase<[String: Int]>.known(["a": 1]).basis == "known")
        #expect(RowBase<[String: Int]>.fresh.basis == "fresh")
        #expect(RowBase<[String: Int]>.unknown(seen: nil).basis == "unknown(none)")
        #expect(RowBase<[String: Int]>.unknown(seen: ["a": 1]).basis == "unknown(seen)")
        #expect(RowBase<[String: Int]>.fresh.plan == RowBase<[String: Int]>.unknown(seen: nil).plan,
                "the precondition: the plan alone does not tell them apart")
    }

    @Test("the start line of the statistics names the base, not only the plan", .needsTheSources)
    func theStatsStartLineNamesTheBase() throws {
        let stats = SyncContractFenceTests.stripped(try String(
            contentsOf: SourceTree.root.appendingPathComponent("Sources/Models/ListeningStats.swift"), encoding: .utf8))
        let line = try #require(stats.split(separator: "\n").first { $0.contains("STATS start:") }, "the start line is gone")
        #expect(line.contains("base=\\(base.basis"), "the start line names the plan, not the base")
    }

    @Test("Skipped rows make the base unknown, never fresh, and it keeps what was read")
    func skippedRowsAreNotNothing() {
        #expect(RowBase<[String: Int]>.afterLoad(rows: nil, skipped: 0).plan == .upsertOnly)
        if case .fresh = RowBase<[String: Int]>.afterLoad(rows: nil, skipped: 0) {} else { Issue.record("nothing decoded, nothing skipped: fresh") }
        if case .unknown(seen: nil) = RowBase<[String: Int]>.afterLoad(rows: nil, skipped: 3) {} else { Issue.record("all skipped: unknown, nothing read") }
        #expect(RowBase<[String: Int]>.afterLoad(rows: ["a": 1], skipped: 1).removable == ["a": 1], "some skipped: unknown with what was read")
        #expect(RowBase<[String: Int]>.afterLoad(rows: ["a": 1], skipped: 0).knownValue == ["a": 1])
    }

    /// The diff against nothing upserts everything and removes nothing:
    /// that is why rows nobody read are safe under a write.
    @Test("The diff against nothing removes nothing")
    func diffAgainstNothingRemovesNothing() {
        let diff = KeyedRowDiff.compute(previous: [:], current: ["a": 1, "b": 2])
        #expect(diff.upserted == ["a": 1, "b": 2])
        #expect(diff.removed.isEmpty)
    }

    /// Without a known base a write diffs against the rows the start read
    /// that are gone, so those are removed and nothing else is; with a known
    /// base against the known rows; fresh or unread against nothing.
    @Test("With an unknown base, what was read and is missing goes along as a removal, nothing else")
    func aReadRowThatIsGoneIsRemoved() {
        let current = ["a": 1, "c": 3]
        let seen = RowBase<[String: Int]>.unknown(seen: ["a": 1, "b": 2])
        #expect(seen.previous(for: current) == ["b": 2])
        #expect(KeyedRowDiff.compute(previous: seen.previous(for: current), current: current).removed == ["b"])
        #expect(RowBase<[String: Int]>.known(["a": 1, "b": 2]).previous(for: current) == ["a": 1, "b": 2])
        #expect(RowBase<[String: Int]>.fresh.previous(for: current).isEmpty)
        #expect(RowBase<[String: Int]>.unknown(seen: nil).previous(for: current).isEmpty)
    }

    /// An empty snapshot that is not meant to empty is refused when it would
    /// remove rows, under a known base and under one that read rows; an empty
    /// snapshot that is the action passes, and so does one that removes
    /// nothing.
    @Test("An empty snapshot without intent is refused if it would remove rows")
    func anEmptySnapshotWithoutIntentIsRefused() {
        let empty: [String: Int] = [:]
        #expect(RowBase<[String: Int]>.known(["a": 1]).refuses(empty, .refused))
        #expect(RowBase<[String: Int]>.unknown(seen: ["a": 1]).refuses(empty, .refused))
        #expect(!RowBase<[String: Int]>.known(["a": 1]).refuses(empty, .allowed))
        #expect(!RowBase<[String: Int]>.fresh.refuses(empty, .refused))
        #expect(!RowBase<[String: Int]>.unknown(seen: nil).refuses(empty, .refused))
        #expect(!RowBase<[String: Int]>.known([:]).refuses(empty, .refused))
        #expect(!RowBase<[String: Int]>.known(["a": 1]).refuses(["b": 2], .refused))
    }

    @Test("The base of a part follows the base of the whole")
    func aPartFollowsTheWhole() {
        let whole = RowBase<[String: [String: Int]]>.unknown(seen: ["days": ["d": 1]])
        #expect(whole.map { $0["days"] ?? [:] }.removable == ["d": 1])
        #expect(RowBase<[String: Int]>.fresh.map(\.count).removable == nil)
        #expect(RowBase<[String: Int]>.known(["a": 1]).map(\.count).knownValue == 1)
    }
}
#endif
