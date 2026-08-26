// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import ABSPlayer

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
        #expect(DeadCatalogItems.liveness(httpStatus: 200, body: healthy) == .alive)
        // Dienst-Ausfall sagt NICHTS ueber das Item.
        #expect(DeadCatalogItems.liveness(httpStatus: nil, body: nil) == .unknown)
        #expect(DeadCatalogItems.liveness(httpStatus: 503, body: nil) == .unknown)
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
}
#endif
