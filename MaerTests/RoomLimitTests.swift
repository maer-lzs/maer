// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// A carrier with a ceiling reckons BEFORE it writes. The store refuses a
/// pot that does not fit without a word, and the watch after the fact can
/// only say that something was refused; these witnesses hold that the
/// refusal happens before the first write, with the numbers, and that a
/// pot under the ceiling goes through unchanged.
struct RoomLimitTests {
    @Test("the reckoning: the bytes beside what the store holds, against the ceiling")
    func theReckoning() {
        #expect(RoomLimit.reckon(bytes: 100, otherBytes: 0, limit: 100).fits)
        #expect(!RoomLimit.reckon(bytes: 101, otherBytes: 0, limit: 100).fits)
        #expect(!RoomLimit.reckon(bytes: 60, otherBytes: 41, limit: 100).fits, "the other keys count")
        #expect(RoomLimit.reckon(bytes: 60, otherBytes: 40, limit: 100).total == 100)
        #expect(RoomLimit.potLimitBytes == ForeignImportPreview.potLimitBytes)
        let bytes = RoomLimit.bytes(ofPropertyList: ["a": [1.0, 2.0]])
        #expect((bytes ?? 0) > 0)
        #expect(RoomLimit.otherBytes(in: ["x": Data(repeating: 7, count: 500), "me": "small"], besides: "me") > 500)
        #expect(RoomLimit.otherBytes(in: ["me": "small"], besides: "me") < 50)
    }

    /// The stand pot on the key-value carrier: a pot over the ceiling is
    /// refused before `set`, with the numbers; a pot under it lands.
    @Test("the stand pot is refused BEFORE the write when it does not fit, and lands when it does") @MainActor
    func theStandPotIsReckonedBeforeTheWrite() {
        let store = InMemoryCloudStore()
        var refusals: [RoomLimit.Reckoning] = []
        let carrier = KeyValueStandCarrier(cloud: store, spacingSeconds: 0, roomLimitBytes: 300,
                                           onRefusal: { refusals.append($0) })
        var big: [String: [Double]] = [:]
        for n in 0..<40 { big["episode-\(n)"] = [Double(n), 1_700_000_000 + Double(n)] }
        carrier.write(upserts: big, removing: [], by: "test")
        #expect(store.dictionary(forKey: KeyValueStandCarrier.blobKey) == nil, "nothing was written")
        #expect(refusals.count == 1)
        #expect((refusals.first?.bytes ?? 0) > 300, "the number says how big the pot is")
        #expect(refusals.first?.limit == 300)
        #expect(refusals.first?.fits == false)
        // A pot under the ceiling goes through unchanged.
        carrier.write(upserts: ["a": [1, 2]], removing: [], by: "test")
        #expect(carrier.stands()["a"] == [1, 2])
        #expect(refusals.count == 1, "a fitting pot is not refused")
        // What the store holds under OTHER keys counts against the ceiling.
        store.set(Data(repeating: 1, count: 280), forKey: "someone-else")
        carrier.write(upserts: ["b": [3, 4]], removing: [], by: "test")
        #expect(carrier.stands()["b"] == nil, "the small pot no longer fits beside the other key")
        #expect(refusals.count == 2)
        #expect((refusals.last?.otherBytes ?? 0) >= 280)
    }

    /// The statistics pot on the key-value carrier, same rule, same refusal.
    @Test("the statistics pot is refused BEFORE the write when it does not fit") @MainActor
    func theStatsPotIsReckonedBeforeTheWrite() {
        let store = InMemoryCloudStore()
        var refusals: [RoomLimit.Reckoning] = []
        let carrier = KeyValueStatsCarrier(store: store, roomLimitBytes: 200, onRefusal: { refusals.append($0) })
        var pot = ListeningStatsData()
        for n in 0..<30 { pot.secondsPerItem["item-\(n)"] = n * 60 }
        carrier.publish(pot, deviceId: "dev-a", by: "test")
        #expect(store.dictionaryRepresentation.isEmpty, "nothing was written")
        #expect(refusals.count == 1)
        #expect((refusals.first?.bytes ?? 0) > 200)
        carrier.publish(ListeningStatsData(), deviceId: "dev-a", by: "test")
        #expect(store.dictionaryRepresentation.count == 1, "an empty pot fits and lands")
        #expect(refusals.count == 1)
    }

    /// The choices blob wrote without a reckoning before; the store
    /// refused it without a word once the pot was full.
    @Test("the choices blob is refused BEFORE the write when it does not fit, and lands when it does") @MainActor
    func theChoicesBlobIsReckonedBeforeTheWrite() {
        let store = InMemoryCloudStore()
        var refusals: [RoomLimit.Reckoning] = []
        let carrier = KeyValueChoiceCarrier(store: store, roomLimitBytes: 300, onRefusal: { refusals.append($0) })
        var big: [String: Any] = [:]
        for n in 0..<40 { big["sort.shelf-\(n)"] = ["t": Double(n), "v": "title"] }
        carrier.storeBlob(big)
        #expect(store.dictionary(forKey: KeyValueChoiceCarrier.blobKey) == nil, "nothing was written")
        #expect(refusals.count == 1)
        #expect((refusals.first?.bytes ?? 0) > 300, "the number says how big the blob is")
        carrier.storeBlob(["sort.books": ["t": 5.0, "v": "title"]])
        #expect(carrier.loadBlob().count == 1, "a fitting blob lands")
        #expect(refusals.count == 1)
        store.set(Data(repeating: 1, count: 280), forKey: "someone-else")
        carrier.storeBlob(["sort.books": ["t": 6.0, "v": "added"]])
        #expect(refusals.count == 2, "what the store holds under other keys counts")
        #expect((refusals.last?.otherBytes ?? 0) >= 280)
    }

    /// The lists and their tombstones are reckoned together and refused
    /// together: half a write would bring a deleted list back.
    @Test("the lists and their tombstones are refused together BEFORE the write when they do not fit") @MainActor
    func thePlaylistsAreReckonedBeforeTheWrite() {
        let store = InMemoryCloudStore()
        var refusals: [RoomLimit.Reckoning] = []
        let carrier = KeyValuePlaylistCarrier(store: store, roomLimitBytes: 400, onRefusal: { refusals.append($0) })
        var snapshot = MaerPlaylistMerge.Snapshot()
        snapshot.lists["l1"] = .init(name: "Mix", updatedAt: 1_700_000_000, itemIds: ["jam:1"], titles: [:])
        for n in 0..<40 { snapshot.tombstones["gone-\(n)"] = 1_699_000_000 + Double(n) }
        carrier.store(snapshot)
        #expect(store.dictionary(forKey: KeyValuePlaylistCarrier.listsKey) == nil, "the lists were not written")
        #expect(store.dictionary(forKey: "maerPlaylistTombstones") == nil, "nor the tombstones")
        #expect(refusals.count == 1)
        #expect((refusals.first?.bytes ?? 0) > 400)
        snapshot.tombstones = [:]
        carrier.store(snapshot)
        #expect(carrier.held().lists["l1"]?.name == "Mix", "a fitting snapshot lands")
        #expect(refusals.count == 1)
    }

    /// Every carrier on the key-value store reckons before it writes; the
    /// claim alone does not, counted here with its reason.
    static let unreckonedWrites: [String: (count: Int, reason: String)] = [
        "ClaimCarrier.swift": (1, "a claim of a few hundred bytes every ten seconds; reckoning the whole store each beat costs more than the claim, and the store's refusal reaches CloudQuotaWatch.note"),
    ]

    @Test("jeder Schreiber auf den Schluessel-Speicher rechnet die Obergrenze vorher; die Ausnahme ist gezaehlt, mit Grund", .needsTheSources)
    func everyKeyValueWriterReckonsFirst() {
        var counts: [String: Int] = [:]
        var reckoningFiles = 0
        for url in SourceTree.files(under: SourceTree.root.appendingPathComponent("Sources")) where url.pathExtension == "swift" {
            guard let text = try? String(contentsOf: url, encoding: .utf8) else {
                Issue.record("unreadable: \(SourceTree.relativePath(of: url))")
                continue
            }
            let code = SyncContractFenceTests.stripped(text)
            guard code.contains("any UserChoiceCloudStore") else { continue }
            let writes = ["store.set(", "cloud.set("].map { code.components(separatedBy: $0).count - 1 }.reduce(0, +)
            let reckonings = ["RoomLimit.reckon(", "RoomLimit.refusal("].map { code.components(separatedBy: $0).count - 1 }.reduce(0, +)
            if reckonings > 0 { reckoningFiles += 1 }
            if writes > 0 && reckonings == 0 { counts[url.lastPathComponent] = writes }
        }
        #expect(reckoningFiles >= 4, "the precondition: the walk found the carriers that reckon")
        #expect(StockDrift.findings(counts: counts, stock: Self.unreckonedWrites.mapValues(\.count)) == [],
                "a key-value writer writes without a reckoning, or a stock above the count")
        #expect(Self.unreckonedWrites.values.allSatisfy { !$0.reason.isEmpty })
    }
}
#endif
