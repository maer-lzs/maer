// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// 🟡 A recognised dead state is remembered, a FAILURE never. The same
/// three-way ladder as with the 401 probe.
struct DeadCatalogItemsTests {
    /// Its own suite per run instead of the real persistence.
    private func freshDefaults() -> UserDefaults {
        UserDefaults(suiteName: "dead-items-\(UUID().uuidString)")!
    }

    @Test("the ladder separates dead from not measured")
    func ladderSeparatesDeadFromUnmeasured() {
        let error = Data(#"{"error":"Unable to fetch metadata"}"#.utf8)
        let healthy = Data(#"{"files":[{"name":"a.mp3"}],"metadata":{"identifier":"x"}}"#.utf8)
        // The measured case: HTTP 200 WITH an error object.
        #expect(DeadCatalogItems.liveness(httpStatus: 200, body: error) == .dead)
        #expect(DeadCatalogItems.liveness(httpStatus: 404, body: nil) == .dead)
        #expect(DeadCatalogItems.liveness(httpStatus: 410, body: nil) == .dead, "ein endgueltiges Weg (410) blieb ungemessen")
        #expect(DeadCatalogItems.liveness(httpStatus: 200, body: healthy) == .alive)
        // A service outage says NOTHING about the item.
        #expect(DeadCatalogItems.liveness(httpStatus: nil, body: nil) == .unknown)
        #expect(DeadCatalogItems.liveness(httpStatus: 503, body: nil) == .unknown)
        #expect(DeadCatalogItems.liveness(httpStatus: 403, body: nil) == .unknown, "eine Abweisung galt als tot")
        #expect(DeadCatalogItems.liveness(httpStatus: 200, body: Data("nonsense".utf8)) == .unknown)
    }

    @Test("a service outage creates NO mark")
    func serviceFailureMarksNothing() {
        let defaults = freshDefaults()
        DeadCatalogItems.note(.unknown, for: "gbia7002555a", defaults: defaults)
        #expect(DeadCatalogItems.marked(defaults: defaults).isEmpty)
        #expect(!DeadCatalogItems.isDead("gbia7002555a", defaults: defaults))
    }

    @Test("a mark expires and gives way to reappearance")
    func markExpiresAndYields() {
        let defaults = freshDefaults()
        let now = Date()
        DeadCatalogItems.note(.dead, for: "gbia7003752a", now: now, defaults: defaults)
        #expect(DeadCatalogItems.isDead("gbia7003752a", now: now, defaults: defaults))
        // After the period the old measurement no longer counts. Archive.org
        // occasionally brings items back.
        let later = now.addingTimeInterval(DeadCatalogItems.ttlDays * 86_400 + 60)
        #expect(!DeadCatalogItems.isDead("gbia7003752a", now: later, defaults: defaults))
        // And a healthy find clears the mark at once.
        DeadCatalogItems.note(.dead, for: "x", now: now, defaults: defaults)
        DeadCatalogItems.note(.alive, for: "x", now: now, defaults: defaults)
        #expect(!DeadCatalogItems.isDead("x", now: now, defaults: defaults))
    }

    @Test("a dead mark has one key: raw, as identifier and as song address the same archive piece")
    func aMarkHasOneKey() {
        let raw = "gbia7002555a"
        let item = FreeCatalog.archivePrefix + raw
        #expect(DeadCatalogItems.key(raw) == raw)
        #expect(DeadCatalogItems.key(item) == raw)
        #expect(DeadCatalogItems.key(CatalogSongID.make(album: item, index: 3)) == raw)
        let jamendo = FreeCatalog.jamendoPrefix + "1234"
        #expect(DeadCatalogItems.key(jamendo) == jamendo, "another catalog's id changed its form")
    }

    /// The metadata fetch writes the raw identifier; the Continue row reads
    /// the item id. The mark reaches it.
    @Test("the mark learned on the metadata fetch (raw) takes the piece out of the Continue row")
    func aRawMarkReachesTheContinueRow() {
        let defaults = freshDefaults()
        let raw = "witness-\(UUID().uuidString)"
        let item = FreeCatalog.archivePrefix + raw
        let history: [String: Any] = ["localPosition.\(item)": [12.0, 1_756_000_000_000.0, 180.0, 1.0]]
        let before = ContinueSources.positionless(in: history, serverKnows: [], deadStore: defaults)
        #expect(before.count == 1, "the probe measures nothing, the row is empty")
        DeadCatalogItems.note(.dead, for: raw, defaults: defaults)
        let after = ContinueSources.positionless(in: history, serverKnows: [], deadStore: defaults)
        #expect(after.isEmpty, "the raw mark did not reach the row that reads the item id")
    }

    /// The real writer of the item id (`ArchiveMetadataLoader.isWithdrawn`)
    /// and the reader of the curated rows, which asks the raw identifier.
    @Test("the mark learned on resolving (identifier) reaches the curated rows that ask raw")
    func anItemMarkReachesTheCuratedRows() async throws {
        let defaults = freshDefaults()
        let raw = "witness-\(UUID().uuidString)"
        let item = FreeCatalog.archivePrefix + raw
        let withdrawn = await ArchiveMetadataLoader.isWithdrawn(
            itemId: item, using: CatalogLoaderWitness.answering(liveness: .dead), defaults: defaults)
        #expect(withdrawn)
        #expect(DeadCatalogItems.isDead(raw, defaults: defaults), "the curated rows do not see the mark")
        #expect(DeadCatalogItems.isDead(CatalogSongID.make(album: item, index: 2), defaults: defaults),
                "a song of the withdrawn item does not see the mark")
    }

    @Test("a mark in the other form of an older build counts and is kept in the one form on the next write")
    func anOlderFormIsReadAndRewritten() {
        let defaults = freshDefaults()
        let now = Date()
        let raw = "gbia7009999a"
        defaults.set([FreeCatalog.archivePrefix + raw: now.timeIntervalSince1970], forKey: DeadCatalogItems.storeKey)
        #expect(DeadCatalogItems.isDead(raw, now: now, defaults: defaults))
        DeadCatalogItems.note(.dead, for: "other", now: now, defaults: defaults)
        let stored = (defaults.dictionary(forKey: DeadCatalogItems.storeKey) as? [String: Double]) ?? [:]
        #expect(Set(stored.keys) == [raw, "other"], "the store keeps two forms: \(stored.keys.sorted())")
    }

    /// Every reader and writer asks through `isDead` and `note`, which take
    /// the one key; nobody reads the marks or their store beside them.
    /// `DerivedStores` names the key only to list it.
    @Test("nobody reads the dead marks past isDead and note", .needsTheSources)
    func nobodyReadsTheMarksBeside() {
        var beside: [String] = []
        for (name, text) in ProjectFileIntegrityTests.sourceTexts(in: ["Sources"]) where name != "DeadCatalogItems.swift" {
            let code = SyncContractFenceTests.stripped(text)
            if code.contains("DeadCatalogItems.marked(") { beside.append("\(name): marked") }
            if code.contains("DeadCatalogItems.storeKey"), name != "DerivedStores.swift" { beside.append("\(name): storeKey") }
        }
        #expect(beside.isEmpty, "the marks are read beside the one key: \(beside)")
    }
}
#endif
