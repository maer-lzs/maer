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
    @Test("Bekannt = Diff, frisch und ungelesen = nur Upserts, unbekannt mit Gelesenem = Gelesenes entfernen (ganz ersetzt nur der Umzug)")
    func planFollowsTheBase() {
        #expect(RowBase<[String: Int]>.known(["a": 1]).plan == .diff)
        #expect(RowBase<[String: Int]>.fresh.plan == .upsertOnly)
        #expect(RowBase<[String: Int]>.unknown(seen: nil).plan == .upsertOnly)
        #expect(RowBase<[String: Int]>.unknown(seen: ["a": 1]).plan == .removeSeen)
        #expect(RowBase<[String: Int]>.known(["a": 1]).knownValue == ["a": 1])
        #expect(RowBase<[String: Int]>.unknown(seen: ["a": 1]).knownValue == nil)
    }

    @Test("Ein gelandeter Schrieb rueckt die Basis vor, ein gescheiterter laesst sie stehen")
    func onlyALandedWriteMovesTheBase() {
        let base = RowBase<[String: Int]>.known(["a": 1])
        #expect(base.landed(["a": 2], success: true).knownValue == ["a": 2])
        #expect(base.landed(["a": 2], success: false).knownValue == ["a": 1])
        // Unknown rows stay unknown, with what was read, after a failed
        // write; a landed write makes the snapshot the known state.
        let unknown = RowBase<[String: Int]>.unknown(seen: ["a": 1])
        #expect(unknown.landed(["a": 2], success: false).removable == ["a": 1])
        #expect(unknown.landed(["a": 2], success: true).plan == .diff)
    }

    @Test("Uebersprungene Zeilen machen die Basis unbekannt, nie frisch, und sie behaelt das Gelesene")
    func skippedRowsAreNotNothing() {
        #expect(RowBase<[String: Int]>.afterLoad(rows: nil, skipped: 0).plan == .upsertOnly)
        if case .fresh = RowBase<[String: Int]>.afterLoad(rows: nil, skipped: 0) {} else { Issue.record("nothing decoded, nothing skipped: fresh") }
        if case .unknown(seen: nil) = RowBase<[String: Int]>.afterLoad(rows: nil, skipped: 3) {} else { Issue.record("all skipped: unknown, nothing read") }
        #expect(RowBase<[String: Int]>.afterLoad(rows: ["a": 1], skipped: 1).removable == ["a": 1], "some skipped: unknown with what was read")
        #expect(RowBase<[String: Int]>.afterLoad(rows: ["a": 1], skipped: 0).knownValue == ["a": 1])
    }

    /// The diff against nothing upserts everything and removes nothing:
    /// that is why rows nobody read are safe under a write.
    @Test("Der Diff gegen nichts entfernt nichts")
    func diffAgainstNothingRemovesNothing() {
        let diff = KeyedRowDiff.compute(previous: [:], current: ["a": 1, "b": 2])
        #expect(diff.upserted == ["a": 1, "b": 2])
        #expect(diff.removed.isEmpty)
    }

    /// Without a known base a write diffs against the rows the start read
    /// that are gone, so those are removed and nothing else is; with a known
    /// base against the known rows; fresh or unread against nothing.
    @Test("Bei unbekannter Grundlage geht Gelesenes, das fehlt, als Entfernung mit, sonst nichts")
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
    @Test("Ein leerer Schnappschuss ohne Absicht wird verweigert, wenn er Zeilen entfernen wuerde")
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

    @Test("Die Grundlage eines Teils folgt der Grundlage des Ganzen")
    func aPartFollowsTheWhole() {
        let whole = RowBase<[String: [String: Int]]>.unknown(seen: ["days": ["d": 1]])
        #expect(whole.map { $0["days"] ?? [:] }.removable == ["d": 1])
        #expect(RowBase<[String: Int]>.fresh.map(\.count).removable == nil)
        #expect(RowBase<[String: Int]>.known(["a": 1]).map(\.count).knownValue == 1)
    }
}
#endif
