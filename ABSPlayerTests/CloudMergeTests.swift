// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later

#if canImport(Testing)
import Testing
@testable import ABSPlayer

/// P6 regression: newest-wins merge semantics of the podcast iCloud sync, the
/// equivalence of the targeted single-id merge, and the double-start guard.
@MainActor
struct CloudMergeTests {

    // MARK: - Full merge (newest wins, no ping-pong)

    @Test func newerTimestampWinsInBothDirections() {
        let outcome = PodcastCloudSync.merge(
            local: ["a": [10, 1000], "b": [20, 5000]],
            cloud: ["a": [99, 2000], "b": [88, 4000]]
        )
        // a: cloud newer → to local; b: local newer → to cloud.
        #expect(outcome.toLocal["a"] == [99, 2000])
        #expect(outcome.toLocal["b"] == nil)
        #expect(outcome.toCloud["b"] == [20, 5000])
        #expect(outcome.toCloud["a"] == nil)
    }

    @Test("Identical state produces NO writes (no ping-pong)")
    func equalTimestampsWriteNothing() {
        let outcome = PodcastCloudSync.merge(
            local: ["a": [10, 1000]],
            cloud: ["a": [10, 1000]]
        )
        #expect(outcome.toLocal.isEmpty)
        #expect(outcome.toCloud.isEmpty)
    }

    @Test func oneSidedEntriesPropagate() {
        let outcome = PodcastCloudSync.merge(
            local: ["onlyLocal": [5, 100]],
            cloud: ["onlyCloud": [7, 200]]
        )
        #expect(outcome.toCloud["onlyLocal"] == [5, 100])
        #expect(outcome.toLocal["onlyCloud"] == [7, 200])
    }

    // MARK: - Single-id merge vs full scan

    @Test("Single-id merge decides exactly like the full scan for value-vs-value")
    func singleMergeMatchesFullScan() {
        let cases: [(local: [Double]?, cloud: [Double]?)] = [
            ([10, 1000], [99, 2000]),   // cloud newer
            ([20, 5000], [88, 4000]),   // local newer
            ([10, 1000], [10, 1000]),   // equal
            ([5, 100], nil),            // only local
        ]
        for c in cases {
            let full = PodcastCloudSync.merge(
                local: c.local.map { ["id": $0] } ?? [:],
                cloud: c.cloud.map { ["id": $0] } ?? [:]
            )
            let single = PodcastCloudSync.mergeSingle(local: c.local, cloud: c.cloud)
            switch single {
            case .adoptCloud(let v): #expect(full.toLocal["id"] == v)
            case .pushLocal(let v): #expect(full.toCloud["id"] == v)
            case .none:
                #expect(full.toLocal.isEmpty)
                #expect(full.toCloud.isEmpty)
            case .pushTombstone:
                Issue.record("tombstone must not occur for value-vs-value cases")
            }
        }
    }

    @Test("Local delete (mark unplayed) pushes a tombstone instead of restoring the old cloud value")
    func localDeletePushesTombstone() {
        // The full scan would restore the cloud value locally; the single-id
        // path deliberately differs: a deleted key means "unplayed", so a fresh
        // zero must win and propagate.
        let single = PodcastCloudSync.mergeSingle(local: nil, cloud: [600, 9999])
        #expect(single == .pushTombstone)
    }

    // MARK: - Double start (logout→login)

    @Test func doubleStartRegistersAtMostOneObserver() {
        let sync = PodcastCloudSync.shared
        sync.start()
        sync.start()
        #expect(sync.observerRegistrations <= 1)
    }
}
#endif
