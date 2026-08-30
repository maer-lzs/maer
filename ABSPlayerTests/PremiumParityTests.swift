// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// Premium-Parität über zwei private Kanäle. Was über den EIGENEN
/// gpodder-Server reisen darf, was nur über iCloud kann, und was in keinem
/// Fall das Gerät verlässt.
struct PremiumParityTests {
    private func show(_ url: String, origin: String? = nil) -> (feedURL: String, origin: String?) {
        (url, origin)
    }

    @Test("Opt-in AUS ist exakt die heutige Y52-Sperre")
    func optInOffKeepsTodaysLock() {
        let split = GPodderVisibleSubscriptions.split([
            show("https://example.org/plain.xml"),
            show("https://premium.example/feed?auth=SECRETTOKEN1234567890"),
            show("https://pinchflat.mesh/feed/a.xml", origin: "pinchflat:home"),
        ], premiumOptIn: false)
        #expect(Set(split.byNorm.values) == ["https://example.org/plain.xml"])
        #expect(split.hiddenNorms.count == 2)
    }

    @Test("Opt-in AN hebt NUR die Token-Sperre — Spiegel bleiben immer draussen")
    func optInLiftsOnlyTheTokenLock() {
        let split = GPodderVisibleSubscriptions.split([
            show("https://example.org/plain.xml"),
            show("https://premium.example/feed?auth=SECRETTOKEN1234567890"),
            show("https://pinchflat.mesh/feed/a.xml", origin: "pinchflat:home"),
        ], premiumOptIn: true)
        // Der Token-Feed reist jetzt mit …
        #expect(split.byNorm.count == 2)
        // … der Spiegel NIE (sein Grund ist Erreichbarkeit, nicht Geheimhaltung).
        #expect(split.hiddenNorms.count == 1)
        #expect(split.hiddenNorms.first?.contains("pinchflat") == true)
    }

    @Test("die Bestands-Versoehnung sagt, wenn sie wartet")
    func twinStateNamesItsSuppression() {
        let rotationTwins = [
            (id: "1", title: "Servus. Grüezi. Hallo.", feedURL: "https://z.example/feed?auth=AAAAAAAAAAAAAAAAAAAA"),
            (id: "2", title: "Servus. Grüezi. Hallo.", feedURL: "https://z.example/feed?auth=BBBBBBBBBBBBBBBBBBBB"),
            (id: "3", title: "Servus. Grüezi. Hallo.", feedURL: "https://z.example/free.xml"),
        ]
        let premium: (String) -> Bool = { $0.contains("auth=") }
        // Solange Rotations-Zwillinge offen sind, WARTET das Angebot. Und
        // sagt es, statt still nichts zu zeigen.
        #expect(PodcastPremiumMatch.twinState(shows: rotationTwins, isPremium: premium)
                == .waitingForRotationMerge)
        // Ohne sie liegt das Paar als Angebot vor.
        let clean = [
            (id: "2", title: "Servus. Grüezi. Hallo.", feedURL: "https://z.example/feed?auth=BBBBBBBBBBBBBBBBBBBB"),
            (id: "3", title: "Servus. Grüezi. Hallo.", feedURL: "https://z.example/free.xml"),
        ]
        guard case .pairs(let pairs) = PodcastPremiumMatch.twinState(shows: clean, isPremium: premium) else {
            Issue.record("erwartet: Paare"); return
        }
        #expect(pairs.count == 1)
        #expect(pairs.first?.freeId == "3" && pairs.first?.premiumId == "2")
    }
}
#endif
