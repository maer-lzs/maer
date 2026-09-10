// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// The pot's transport is a carrier; the merge rule is not. A carrier
/// that only records what it is told proves the runner talks to nothing
/// else: stands come in through `stands`, what moved goes out through
/// `write` (upserts and the entries that left the travel set), a delivery
/// wakes the runner through `onChange`. And the key-value store is the one
/// place that names the blob: the runner's file does not.
struct StandCarrierTests {
    @MainActor
    final class RecordingCarrier: StandCarrier {
        let name = "fake"
        /// A roomy carrier by default; the pruning witness names it.
        var hasRoomLimit = false
        var held: [String: [Double]] = [:]
        var writes: [(upserts: [String: [Double]], removing: Set<String>, by: String)] = []
        var deliver: (@MainActor () -> Void)?

        func stands() -> [String: [Double]] { held }
        func write(upserts: [String: [Double]], removing: Set<String>, by caller: String) {
            writes.append((upserts, removing, caller))
            for id in removing { held[id] = nil }
            for (id, entry) in upserts { held[id] = entry }
        }
        func start(onChange: @escaping @MainActor () -> Void) { deliver = onChange }
        func refresh(by caller: String) async {}
    }

    @Test("die Raeumung gehoert dem Deckel, nicht dem Topf: der Schluessel-Traeger hat einen, ein geraeumiger Traeger nicht") @MainActor
    func pruningBelongsToTheCeiling() {
        // The blob holds a megabyte for everything, so a finished episode
        // of an unsubscribed show leaves it. CloudKit has room, and there
        // "unsubscribed here" is not "unsubscribed anywhere": the other
        // device, which still follows the show, wrote the same stands back
        // every round (measured on 33, six of them ping-ponging).
        let keyValue = KeyValueStandCarrier(cloud: InMemoryCloudStore(), spacingSeconds: 0)
        #expect(keyValue.hasRoomLimit, "one key, one megabyte")
        #expect(!RecordingCarrier().hasRoomLimit)
        // The rule itself is unchanged: it still says what may leave a
        // capped pot.
        let finished = [100.0, 1_000, 100]
        #expect(!PodcastCloudSync.travels(id: "rss:gone:ep", entry: finished, isSubscribedShow: { _ in false }))
        #expect(PodcastCloudSync.travels(id: "rss:kept:ep", entry: finished, isSubscribedShow: { _ in true }))
    }

    @Test("der Laeufer liest und schreibt nur ueber den Traeger: fremd neuer kommt an, eigen neuer geht hinaus, Grabstein ist ein Schrieb") @MainActor
    func runnerTalksOnlyToTheCarrier() {
        guard AppStorageKeys.podcastICloudSyncEnabled else {
            // The runner is silent without the switch; the fence below still holds.
            return
        }
        let carrier = RecordingCarrier()
        let sync = PodcastCloudSync(carrier: carrier)
        let id = "rss:standcarrier:\(UUID().uuidString)"
        defer { ListeningStore.clearBackup(id) }

        // The carrier holds a stand this device has none for. The play
        // start asks receive-only: it writes nothing, above all no zero
        // (the single-id rule reads "no local stand" as a deliberate
        // unplayed mark, which only a pushing caller may send).
        let future = Date().timeIntervalSince1970 * 1000 + 60_000
        carrier.held[id] = [600, future, 3_600]
        sync.reconcile(changedId: id, pushing: false)
        #expect(carrier.writes.isEmpty, "a receive-only pass never writes a tombstone")
        // The full scan adopts the foreign stand, still without a write.
        sync.reconcile(pushing: false, caller: "witness")
        #expect(ListeningStore.backup(id)?[0] == 600)
        #expect(carrier.writes.isEmpty)

        // The device moves on: the newer local stand goes out through the carrier.
        ListeningStore.store(id, entry: [700, future + 1_000, 3_600])
        sync.reconcile(changedId: id, pushing: true)
        #expect(carrier.writes.count == 1)
        #expect(carrier.writes.last?.upserts[id]?[0] == 700)
        #expect(carrier.writes.last?.removing.isEmpty == true)
        #expect(carrier.held[id]?[0] == 700)

        // Marked unplayed here (no local stand any more): a zero travels
        // as a write, never as a removal.
        ListeningStore.clearBackup(id)
        carrier.held[id] = [700, future + 1_000, 3_600]
        sync.reconcile(changedId: id, pushing: true)
        #expect(carrier.writes.last?.upserts[id]?[0] == 0)
    }

    @Test("das Sende-Tor sitzt im Laeufer: innerhalb der Kadenz des Traegers sendet der Tick nicht, ein Anlass immer") @MainActor
    func theSendGateIsTheRunners() {
        guard AppStorageKeys.podcastICloudSyncEnabled else { return }
        let carrier = RecordingCarrier()
        let sync = PodcastCloudSync(carrier: carrier)
        let id = "rss:sendgate:\(UUID().uuidString)"
        defer { ListeningStore.clearBackup(id) }
        let future = Date().timeIntervalSince1970 * 1000 + 60_000
        ListeningStore.store(id, entry: [100, future, 3_600])
        // The first tick sends (nothing was ever sent), the next within the
        // carrier's minute does not, a deliberate occasion always does.
        sync.sendState(changedId: id, deliberate: false, nowMs: 1_000_000)
        #expect(carrier.writes.count == 1)
        ListeningStore.store(id, entry: [200, future + 1_000, 3_600])
        sync.sendState(changedId: id, deliberate: false, nowMs: 1_030_000)
        #expect(carrier.writes.count == 1, "within the cadence the tick does not send")
        sync.sendState(changedId: id, deliberate: true, nowMs: 1_031_000)
        #expect(carrier.writes.count == 2, "an occasion always sends")
        #expect(sync.lastSendAtMs == 1_031_000)
        ListeningStore.store(id, entry: [300, future + 2_000, 3_600])
        sync.sendState(changedId: id, deliberate: false, nowMs: 1_091_000)
        #expect(carrier.writes.count == 3, "the cadence is due again")
    }

    @Test("der Zaun: nur der Schluessel-Traeger nennt den Speicher und den Blob") @MainActor
    func onlyTheCarrierNamesTheStore() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let runner = try String(contentsOf: root.appendingPathComponent("Sources/Networking/PodcastCloudSync.swift"), encoding: .utf8)
        let code = runner.split(separator: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }.joined(separator: "\n")
        for word in ["NSUbiquitousKeyValueStore", "UserChoiceCloudStore", "CloudKeyValue", "store.set(", "store.dictionary(", "store.synchronize(", "podcastProgress", "blobKey"] {
            #expect(!code.contains(word), "the runner names the store: \(word)")
        }
        #expect(KeyValueStandCarrier.blobKey == "podcastProgress")
    }

    @Test("der Schluessel-Traeger: ein Blob, Einfuegen und Entfernen, nur Eintraege mit Moment") @MainActor
    func keyValueCarrierHoldsOneBlob() {
        let store = InMemoryCloudStore()
        let carrier = KeyValueStandCarrier(cloud: store, spacingSeconds: 0)
        #expect(carrier.name == "kvs")
        #expect(carrier.stands().isEmpty)
        carrier.write(upserts: ["a": [1, 2], "b": [3, 4, 5]], removing: [], by: "test")
        #expect(carrier.stands()["a"] == [1, 2])
        #expect(carrier.stands()["b"] == [3, 4, 5])
        // A half entry in the blob is not a stand.
        store.set(["a": [1, 2], "b": [3, 4, 5], "c": [9]], forKey: KeyValueStandCarrier.blobKey)
        #expect(carrier.stands().keys.sorted() == ["a", "b"])
        // Removing and inserting in one write: the blob is written once.
        carrier.write(upserts: ["d": [7, 8]], removing: ["a"], by: "test")
        let blob = store.dictionary(forKey: KeyValueStandCarrier.blobKey)
        #expect(blob?["a"] == nil)
        #expect((blob?["d"] as? [Double]) == [7, 8])
        // Nothing to write is no write; the half entry stays no stand.
        carrier.write(upserts: [:], removing: [], by: "test")
        #expect(carrier.stands().keys.sorted() == ["b", "d"])
    }

    @Test("der nachlaufende Schrieb: innerhalb der Spanne wartet der zweite und traegt den Stand des ersten mit") @MainActor
    func trailingWriteKeepsTheQueuedState() async throws {
        let store = InMemoryCloudStore()
        let carrier = KeyValueStandCarrier(cloud: store, spacingSeconds: 0.2)
        carrier.write(upserts: ["a": [1, 2]], removing: [], by: "first")
        #expect(carrier.stands()["a"] == [1, 2], "the first write goes at once")
        carrier.write(upserts: ["b": [3, 4]], removing: [], by: "second")
        carrier.write(upserts: ["c": [5, 6]], removing: ["a"], by: "third")
        #expect(carrier.stands().keys.sorted() == ["a"], "within the spacing nothing landed yet")
        try await Task.sleep(for: .milliseconds(400))
        #expect(carrier.stands().keys.sorted() == ["b", "c"], "one trailing write carries both, and the removal")
    }
}
#endif
