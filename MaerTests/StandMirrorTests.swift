// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// The mirror follows every write path of the stock in order, pours the
/// defaults into the table once at start, and leaves the keys where they are.
/// Serialized: the hook on the stock is one global, and each witness installs
/// its own mirror on it.
@Suite(.serialized)
struct StandMirrorTests {
    private func suite() -> UserDefaults {
        UserDefaults(suiteName: "stand-mirror-\(UUID().uuidString)")!
    }

    private func mirror() async throws -> (StandMirror, StandStore) {
        let store = try await StandStore(connection: try SQLiteConnection(path: ":memory:"))
        return (StandMirror(store: store), store)
    }

    @Test("Jeder Schreibweg des Bestands landet in der Tabelle, in seiner Reihenfolge")
    func everyWritePathLandsInOrder() async throws {
        let defaults = suite()
        let (mirror, store) = try await mirror()
        defer { ListeningStore.onWrite = nil }
        mirror.start(defaults: defaults)
        let t = 1_700_000_000_000.0
        ListeningStore.record("rss:a", position: 600, duration: 3600, atMs: t, in: defaults)
        ListeningStore.store("rss:b", entry: [12, t + 1, 900], in: defaults)
        ListeningStore.noteStartedForm("abs:c", form: .work, atMs: t + 2, in: defaults)
        ListeningStore.clearBackup("rss:a", in: defaults)
        ListeningStore.move(from: "rss:b", to: "abspod:b", in: defaults)
        ListeningStore.store("local:gone", entry: [7, t + 3], in: defaults)
        ListeningStore.forgetUserDeleted("local:gone", in: defaults)
        // Another instance is not this stock: nothing of it may arrive.
        ListeningStore.store("rss:elsewhere", entry: [1, t], in: suite())
        await mirror.awaitPendingWrites()
        #expect(try await store.stand(for: "rss:a") == nil, "recorded, then cleared: the clear is the last word")
        #expect(try await store.stand(for: "rss:b") == nil, "moved away")
        #expect(try await store.stand(for: "abspod:b")?.entry == ListeningStore.backup("abspod:b", in: defaults))
        #expect(try await store.stand(for: "abs:c")?.entry == ListeningStore.backup("abs:c", in: defaults))
        #expect(try await store.stand(for: "abs:c")?.form == ProgressMark.StartedForm.work.rawValue)
        #expect(try await store.stand(for: "rss:elsewhere") == nil)
        #expect(try await store.stand(for: "local:gone") == nil, "the user deleted the item, its row goes with it")
        #expect(try await store.count() == 2)
    }

    /// The start is the normal case (Rule 9): a stock of old entries in every
    /// shape, one transaction, keys untouched, a second start writes nothing
    /// and never over a newer row.
    @Test("Der Start giesst den Altbestand einmal in die Tabelle; die Schluessel bleiben; ein zweiter Start schreibt nichts")
    func startPoursTheStockOnceAndKeepsTheKeys() async throws {
        let defaults = suite()
        let t = 1_700_000_000_000.0
        let stock: [String: [Double]] = ["rss:two": [12, t], "abs:three": [600, t + 1, 3600],
                                         "abs:four": [30, t + 2, 0, 1], "radio:live": [5, t + 3]]
        for (id, entry) in stock { defaults.set(entry, forKey: AppStorageKeys.localPosition(id)) }
        let (first, store) = try await mirror()
        defer { ListeningStore.onWrite = nil }
        first.start(defaults: defaults)
        await first.awaitPendingWrites()
        #expect(try await store.count() == 3, "a live stream keeps no position, the class filter of the stock applies")
        for id in ["rss:two", "abs:three", "abs:four"] {
            #expect(try await store.stand(for: id)?.entry == stock[id], "shape kept for \(id)")
            #expect(defaults.array(forKey: AppStorageKeys.localPosition(id)) as? [Double] == stock[id],
                    "the key stays: the defaults remain the stock every reader asks")
        }
        // A newer row (a write that happened between two starts) survives.
        try await store.upsert(Stand(itemId: "rss:two", entry: [999, t + 10])!)
        let second = StandMirror(store: store)
        second.start(defaults: defaults)
        await second.awaitPendingWrites()
        #expect(try await store.count() == 3)
        #expect(try await store.stand(for: "rss:two")?.position == 999)
    }
}
#endif
