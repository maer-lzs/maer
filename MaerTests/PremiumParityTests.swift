// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// Premium parity over two private channels. What may travel over the OWN
/// gpodder server, what can only go over iCloud, and what never
/// leaves the device.
struct PremiumParityTests {
    private func show(_ url: String, origin: String? = nil) -> (feedURL: String, origin: String?) {
        (url, origin)
    }

    @Test("Opt-in OFF is exactly today's Y52 lock")
    func optInOffKeepsTodaysLock() {
        let split = GPodderVisibleSubscriptions.split([
            show("https://example.org/plain.xml"),
            show("https://premium.example/feed?auth=SECRETTOKEN1234567890"),
            show("https://pinchflat.mesh/feed/a.xml", origin: "pinchflat:home"),
        ], premiumOptIn: false)
        #expect(Set(split.byNorm.values) == ["https://example.org/plain.xml"])
        #expect(split.hiddenNorms.count == 2)
    }

    @Test("Opt-in ON lifts ONLY the token lock, mirrors always stay out")
    func optInLiftsOnlyTheTokenLock() {
        let split = GPodderVisibleSubscriptions.split([
            show("https://example.org/plain.xml"),
            show("https://premium.example/feed?auth=SECRETTOKEN1234567890"),
            show("https://pinchflat.mesh/feed/a.xml", origin: "pinchflat:home"),
        ], premiumOptIn: true)
        // The token feed now travels along …
        #expect(split.byNorm.count == 2)
        // … the mirror NEVER (its reason is reachability, not secrecy).
        #expect(split.hiddenNorms.count == 1)
        #expect(split.hiddenNorms.first?.contains("pinchflat") == true)
    }

    @Test("the stock reconciliation says when it is waiting")
    func twinStateNamesItsSuppression() {
        let rotationTwins = [
            (id: "1", title: "Servus. Grüezi. Hallo.", feedURL: "https://z.example/feed?auth=AAAAAAAAAAAAAAAAAAAA"),
            (id: "2", title: "Servus. Grüezi. Hallo.", feedURL: "https://z.example/feed?auth=BBBBBBBBBBBBBBBBBBBB"),
            (id: "3", title: "Servus. Grüezi. Hallo.", feedURL: "https://z.example/free.xml"),
        ]
        let premium: (String) -> Bool = { $0.contains("auth=") }
        // As long as rotation twins are open, the offer WAITS. And
        // says so, instead of silently showing nothing.
        #expect(PodcastPremiumMatch.twinState(shows: rotationTwins, isPremium: premium)
                == .waitingForRotationMerge)
        // Without them the pair is present as an offer.
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
