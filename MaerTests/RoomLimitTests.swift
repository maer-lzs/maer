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
}
#endif
