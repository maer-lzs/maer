// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// An imported stock of the size a real account produced (1652 states,
/// stamped 0 because the source records no moment) through the iCloud
/// merge: every state travels to the empty cloud, every one lands on
/// the second device, and the blob stays far under the store's limit.
struct CloudBlobRoundTripTests {
    private func stock(_ count: Int) -> [String: [Double]] {
        var out: [String: [Double]] = [:]
        for i in 0..<count {
            let guid = "rss:b39264a09b989645:https://feeds.example.invalid/episodes/\(String(format: "%04d", i))-a-fairly-long-permalink-guid"
            out[guid] = i % 10 == 0 ? [600, 0, 2_798] : [2_798, 0, 2_798]
        }
        return out
    }

    @Test("1700 importierte Staende mit Stempel 0 reisen in den leeren Topf und landen auf Geraet B")
    func importedStockTravels() throws {
        let local = stock(1_700)
        let first = PodcastCloudSync.merge(local: local, cloud: [:])
        #expect(first.toCloud.count == 1_700)
        #expect(first.toLocal.isEmpty)
        // Device B: nothing local, the cloud carries the stock.
        let second = PodcastCloudSync.merge(local: [:], cloud: first.toCloud)
        #expect(second.toLocal.count == 1_700)
        #expect(second.toCloud.isEmpty)
        // And a stamp of zero is still a stamp: the same stock again is a
        // tie on both sides and writes nothing (no ping-pong).
        let again = PodcastCloudSync.merge(local: second.toLocal, cloud: first.toCloud)
        #expect(again.toLocal.isEmpty && again.toCloud.isEmpty)
    }

    @Test("der Blob bleibt weit unter dem Deckel des Schluesselwert-Speichers")
    func blobStaysSmall() throws {
        let blob = stock(1_700) as [String: Any]
        let data = try PropertyListSerialization.data(fromPropertyList: blob, format: .binary, options: 0)
        // 1 MB is the store's total; measured on a real export: 1395 states
        // took 162 KB. The long guids here are the worst realistic case.
        #expect(data.count < 400_000, "blob is \(data.count) bytes")
    }
}
#endif
