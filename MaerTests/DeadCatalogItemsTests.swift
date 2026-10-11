// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// 🟡 Erkanntes Tot-Sein wird gemerkt, ein FEHLSCHLAG nie. Dieselbe
/// Drei-Wege-Leiter wie bei der 401-Probe.
struct DeadCatalogItemsTests {
    /// Eigene Suite je Lauf statt der echten Persistenz.
    private func freshDefaults() -> UserDefaults {
        UserDefaults(suiteName: "dead-items-\(UUID().uuidString)")!
    }

    @Test("die Leiter trennt tot von nicht-gemessen")
    func ladderSeparatesDeadFromUnmeasured() {
        let error = Data(#"{"error":"Unable to fetch metadata"}"#.utf8)
        let healthy = Data(#"{"files":[{"name":"a.mp3"}],"metadata":{"identifier":"x"}}"#.utf8)
        // Der gemessene Fall: HTTP 200 MIT Fehlerobjekt.
        #expect(DeadCatalogItems.liveness(httpStatus: 200, body: error) == .dead)
        #expect(DeadCatalogItems.liveness(httpStatus: 404, body: nil) == .dead)
        #expect(DeadCatalogItems.liveness(httpStatus: 410, body: nil) == .dead, "ein endgueltiges Weg (410) blieb ungemessen")
        #expect(DeadCatalogItems.liveness(httpStatus: 200, body: healthy) == .alive)
        // Dienst-Ausfall sagt NICHTS ueber das Item.
        #expect(DeadCatalogItems.liveness(httpStatus: nil, body: nil) == .unknown)
        #expect(DeadCatalogItems.liveness(httpStatus: 503, body: nil) == .unknown)
        #expect(DeadCatalogItems.liveness(httpStatus: 403, body: nil) == .unknown, "eine Abweisung galt als tot")
        #expect(DeadCatalogItems.liveness(httpStatus: 200, body: Data("nonsense".utf8)) == .unknown)
    }

    @Test("ein Dienst-Ausfall erzeugt KEINE Markierung")
    func serviceFailureMarksNothing() {
        let defaults = freshDefaults()
        DeadCatalogItems.note(.unknown, for: "gbia7002555a", defaults: defaults)
        #expect(DeadCatalogItems.marked(defaults: defaults).isEmpty)
        #expect(!DeadCatalogItems.isDead("gbia7002555a", defaults: defaults))
    }

    @Test("eine Markierung laeuft ab und weicht dem Wiederauftauchen")
    func markExpiresAndYields() {
        let defaults = freshDefaults()
        let now = Date()
        DeadCatalogItems.note(.dead, for: "gbia7003752a", now: now, defaults: defaults)
        #expect(DeadCatalogItems.isDead("gbia7003752a", now: now, defaults: defaults))
        // Nach der Frist zaehlt die alte Messung nicht mehr. Archive.org
        // holt Items gelegentlich zurueck.
        let later = now.addingTimeInterval(DeadCatalogItems.ttlDays * 86_400 + 60)
        #expect(!DeadCatalogItems.isDead("gbia7003752a", now: later, defaults: defaults))
        // Und ein gesunder Fund raeumt die Markierung sofort ab.
        DeadCatalogItems.note(.dead, for: "x", now: now, defaults: defaults)
        DeadCatalogItems.note(.alive, for: "x", now: now, defaults: defaults)
        #expect(!DeadCatalogItems.isDead("x", now: now, defaults: defaults))
    }

    @Test("eine Tot-Marke hat einen Schluessel: roh, als Kennung und als Song-Adresse dasselbe Archiv-Stueck")
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
    @Test("die beim Metadaten-Abruf gelernte Marke (roh) nimmt das Stueck aus der Weiterhoeren-Reihe")
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
    @Test("die beim Aufloesen gelernte Marke (Kennung) erreicht die kuratierten Reihen, die roh fragen")
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

    @Test("eine Marke in der anderen Form eines aelteren Baus zaehlt und wird beim naechsten Schrieb in der einen Form gefuehrt")
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
    @Test("niemand liest die Tot-Marken an isDead und note vorbei", .needsTheSources)
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
