// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// A choice entry whose value is of a kind this build cannot read (a newer
/// build wrote it) is neither a value nor a tombstone. The merge decides
/// over it by time and never applies it; every carrier passes it on as it
/// came; a local value of an unknown kind makes no entry at all.
@MainActor
struct UserChoiceUnknownKindTests {

    private let key = "podcastSort.feed:unknown-kind"

    private func device(_ cloud: UserChoiceFakeCloud, now: Double)
        -> (sync: UserChoiceCloudSync, defaults: UserDefaults, suite: String) {
        let suite = "choice-unknown-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        var clock = now
        let sync = UserChoiceCloudSync(defaults: defaults, cloud: cloud,
                                       syncEnabled: { true },
                                       now: { clock += 1; return clock }, idFormSettled: { true })
        return (sync, defaults, suite)
    }

    private func cleanup(_ suite: String) {
        UserDefaults().removePersistentDomain(forName: suite)
    }

    private func blob(_ cloud: UserChoiceFakeCloud) -> [String: Any] {
        cloud.storage[UserChoiceCloudSync.blobKey] as? [String: Any] ?? [:]
    }

    /// An entry as a newer build would write it into the key-value blob: a
    /// plist value of a kind `UserChoiceValue` has no case for.
    private func unknownEntry(t: Double, marker: Date) -> [String: Any] {
        ["t": t, "v": marker]
    }

    // MARK: - The rule, pure

    @Test("ueber einen Eintrag unbekannter Art entscheidet die Zeit, angewandt wird er nie")
    func theMergeDecidesByTimeAndNeverApplies() throws {
        let unknown = try #require(UserChoiceEntry.from(plist: ["t": 5000.0, "v": Date()]))
        #expect(unknown.unknownKind, "the precondition: a value of no known kind reads as unknown")
        #expect(unknown.value == nil)
        let tombstone = try #require(UserChoiceEntry.from(plist: ["t": 5000.0]))
        #expect(!tombstone.unknownKind, "an entry without a value stays a tombstone")

        let olderValue = UserChoiceEntry(value: .bool(true), t: 1000)
        let newerValue = UserChoiceEntry(value: .bool(true), t: 9000)
        let newerClear = UserChoiceEntry(value: nil, t: 9000)
        let sameStamp = UserChoiceEntry(value: .bool(true), t: 5000)
        #expect(UserChoiceMerge.decide(local: olderValue, cloud: unknown) == .none,
                "newer unknown: it holds the key, the local value is neither cleared nor written out")
        #expect(UserChoiceMerge.decide(local: nil, cloud: unknown) == .none,
                "nothing here: an unknown entry is never adopted")
        #expect(UserChoiceMerge.decide(local: newerValue, cloud: unknown) == .push(9000),
                "older unknown: the local statement replaces it")
        #expect(UserChoiceMerge.decide(local: newerClear, cloud: unknown) == .push(9000),
                "a newer tombstone replaces it too")
        #expect(UserChoiceMerge.decide(local: sameStamp, cloud: unknown) == .none,
                "an equal stamp is no win for the local value")
    }

    // MARK: - The key-value blob

    @Test("ein neuerer Eintrag unbekannter Art loescht hier nichts und geht beim naechsten Schrieb unveraendert hinaus")
    func aNewerUnknownEntryDeletesNothingAndTravelsBack() throws {
        let cloud = UserChoiceFakeCloud()
        let a = device(cloud, now: 1000)
        defer { cleanup(a.suite) }
        a.defaults.set(false, forKey: key)
        a.sync.noteScalar(key: key, value: false)
        let marker = Date(timeIntervalSince1970: 1_700_000_000)
        var planted = blob(cloud)
        planted[key] = unknownEntry(t: 10_000_000, marker: marker)
        cloud.storage[UserChoiceCloudSync.blobKey] = planted

        a.sync.reconcile()
        #expect(a.defaults.object(forKey: key) as? Bool == false, "the local value stays as it is")
        // A second statement makes the runner write the whole blob again.
        a.defaults.set(true, forKey: PodcastShowPreferences.sortKey(showId: "feed:other"))
        a.sync.noteScalar(key: PodcastShowPreferences.sortKey(showId: "feed:other"), value: true)
        a.sync.reconcile()
        let entry = try #require(blob(cloud)[key] as? [String: Any])
        #expect(entry["t"] as? Double == 10_000_000, "the unknown entry keeps its time")
        #expect(entry["v"] as? Date == marker, "and its value, exactly as it came")
        #expect(a.defaults.object(forKey: key) as? Bool == false, "and nothing here was cleared")
    }

    @Test("ein aelterer Eintrag unbekannter Art verliert gegen die lokale Aussage, ein neuerer Grabstein ersetzt ihn")
    func anOlderUnknownEntryLoses() throws {
        let cloud = UserChoiceFakeCloud()
        let a = device(cloud, now: 1000)
        defer { cleanup(a.suite) }
        cloud.storage[UserChoiceCloudSync.blobKey] = [key: unknownEntry(t: 10, marker: Date())]
        a.defaults.set(false, forKey: key)
        a.sync.noteScalar(key: key, value: false)
        a.sync.reconcile()
        let replaced = try #require(UserChoiceEntry.from(plist: blob(cloud)[key]))
        #expect(replaced.value == .bool(false) && !replaced.unknownKind, "the local value replaced it: \(replaced)")

        // A newer clear noted on a device that reads the document fresh (a
        // runner keeps the document it read last until its next round): the
        // note meets the unknown entry itself and must not take it for the
        // same statement.
        cloud.storage[UserChoiceCloudSync.blobKey] = [key: unknownEntry(t: 10, marker: Date())]
        let b = device(cloud, now: 2000)
        defer { cleanup(b.suite) }
        b.sync.noteScalar(key: key, value: nil)
        let cleared = try #require(UserChoiceEntry.from(plist: blob(cloud)[key]))
        #expect(cleared.value == nil && !cleared.unknownKind, "a newer clear replaced it as a tombstone: \(cleared)")

        // And a clear that only the stamp remembers, at the next round.
        cloud.storage[UserChoiceCloudSync.blobKey] = [key: unknownEntry(t: 10, marker: Date())]
        a.defaults.removeObject(forKey: key)
        a.sync.reconcile()
        let derived = try #require(UserChoiceEntry.from(plist: blob(cloud)[key]))
        #expect(derived.value == nil && !derived.unknownKind && derived.t > 10,
                "the round replaced it with the newer tombstone: \(derived)")
    }

    @Test("ein lokaler Wert unbekannter Art erzeugt keinen Grabstein")
    func aLocalValueOfAnUnknownKindMakesNoTombstone() {
        let cloud = UserChoiceFakeCloud()
        let a = device(cloud, now: 1000)
        defer { cleanup(a.suite) }
        a.defaults.set(Date(), forKey: key)
        a.sync.noteScalar(key: key, value: Date())
        #expect(blob(cloud)[key] == nil, "the note sent nothing")
        a.sync.reconcile()
        #expect(blob(cloud)[key] == nil, "the reconcile sent nothing either, no tombstone")
        #expect(a.defaults.object(forKey: key) is Date, "and the local value stays")

        // With a stamp: the key carried a known value once, the document
        // lost it, and the local value is now of an unknown kind. Read as
        // nil with its stamp it would go out as a tombstone.
        a.defaults.set(false, forKey: key)
        a.sync.noteScalar(key: key, value: false)
        #expect(a.sync.localStamps()?[key] != nil, "the precondition: the key has a stamp")
        cloud.storage[UserChoiceCloudSync.blobKey] = [:]
        a.defaults.set(Date(), forKey: key)
        a.sync.reconcile()
        #expect(blob(cloud)[key] == nil, "a stamped local value of an unknown kind sends no tombstone")
    }

    // MARK: - The service document and the cloud records

    @Test("das Dienst-Dokument reicht einen unbekannten Tag unveraendert durch")
    func theServiceWirePassesAnUnknownTagThrough() throws {
        let body = Data(#"{"entries":{"podcastSort.feed:unknown-kind":{"t":5000,"v":{"z":"neu"}}}}"#.utf8)
        let decoded = try #require(MaerSyncChoiceWire.decode(body))
        let entry = try #require(UserChoiceEntry.from(plist: decoded[key]))
        #expect(entry.unknownKind && entry.t == 5000, "read as unknown, not skipped and not a tombstone: \(entry)")
        let again = try MaerSyncChoiceWire.encode(decoded)
        #expect(again == body, "written back byte for byte: \(String(decoding: again, as: UTF8.self))")
    }

    @Test("ein Datensatz unbekannter Art bleibt in der Wolke und wird kein Grabstein")
    func aCloudRecordOfAnUnknownKindStays() throws {
        let payload = Data(#"{"z":"neu"}"#.utf8)
        let record = CloudChoiceRecord(key: key, payload: payload, t: 5000, tombstone: false)
        let blob = CloudKitChoiceCarrier.blob(of: [key: record])
        let entry = try #require(UserChoiceEntry.from(plist: blob[key]))
        #expect(entry.unknownKind, "kept in the blob as unknown, not dropped: \(blob)")
        #expect(CloudKitChoiceCarrier.records(for: blob) == [key: record],
                "the desired set keeps the record as it came, so no removal goes out")
        let united = CloudKitChoiceCarrier.united(cloud: [:], blob: blob)
        #expect(CloudKitChoiceCarrier.records(for: united) == [key: record], "the union keeps it raw")
    }

    // MARK: - The format

    /// The service wire tags every kind of value; a new kind is a new tag
    /// and an older build cannot read it, so it raises the format. Held at
    /// the source: the cases of `UserChoiceValue` against format 1.
    @Test("eine neue Wert-Art hebt das Format des Dienst-Dokuments", .needsTheSources)
    func aNewKindOfValueRaisesTheFormat() throws {
        let text = try String(contentsOf: SourceTree.root.appendingPathComponent("Sources/Models/UserChoiceSync.swift"),
                              encoding: .utf8)
        let start = try #require(text.range(of: "enum UserChoiceValue: Equatable {"))
        let end = try #require(text.range(of: "var plist: Any {", range: start.upperBound..<text.endIndex))
        let body = text[start.upperBound..<end.lowerBound]
        let cases = body.split(separator: "\n").compactMap { line -> String? in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("case "), let open = trimmed.firstIndex(of: "(") else { return nil }
            return String(trimmed[trimmed.index(trimmed.startIndex, offsetBy: 5)..<open])
        }
        #expect(cases.count >= 6, "the fence read the cases: \(cases)")
        #expect(MaerSyncChoiceWire.format == 1 && cases == ["string", "bool", "int", "double", "stringList", "data"],
                "a new kind of value gets its tag and raises MaerSyncChoiceWire.format: \(cases)")
    }
}
#endif
