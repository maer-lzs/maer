// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Testing
@testable import Maer

// MARK: - 🔴 One visibility rule, mirrors never leak

struct GPodderVisibilityTests {
    private func show(_ url: String, origin: String? = nil) -> (feedURL: String, origin: String?) {
        (url, origin)
    }

    @Test func mirrorsAndTokenFeedsStayInvisibleToGpodder() {
        let split = GPodderVisibleSubscriptions.split([
            show("https://example.org/plain.xml"),
            show("https://pinchflat.mesh/feed/abc.xml", origin: "pinchflat:home"),
            show("https://premium.example/feed?auth=SECRETTOKEN1234567890"),
        ])
        #expect(Set(split.byNorm.values) == ["https://example.org/plain.xml"])
        #expect(split.hiddenNorms.count == 2)
        // Both exclusions land in `hidden`, so neither can be re-adopted.
        #expect(split.hiddenNorms.contains(
            PodcastSubscriptions.normalizeFeedURL("https://pinchflat.mesh/feed/abc.xml")))
    }

    @Test func aDirectSubscriptionBeatsItsMirror() {
        // Same URL both mirrored and subscribed directly: the user's own
        // subscription decides. Visible, not hidden.
        let url = "https://example.org/show.xml"
        let split = GPodderVisibleSubscriptions.split([show(url, origin: "pinchflat:home"), show(url)])
        #expect(split.byNorm.count == 1)
        #expect(split.hiddenNorms.isEmpty)
    }

    @Test func mirrorsOnTheServerAreCleanedUpNotReAdopted() {
        // The measured state: four mirrors were pushed by the old half-rule and
        // sit on the server and in prev; locally they are mirrors (hidden).
        let mirrors = Set((1...4).map { "https://pinchflat.mesh/feed/\($0).xml" })
        let normal = Set(["https://example.org/a.xml", "https://example.org/b.xml"])
        let merge = GPodderSubscriptionMerge.compute(
            local: normal, server: normal.union(mirrors), prev: normal.union(mirrors),
            hiddenLocally: mirrors)
        // NOT re-subscribed locally …
        #expect(merge.addLocally.isEmpty)
        // … and removed from the server despite being four (> the plausibility
        // limit): a grounded cleanup, like the user's own unsubscribes.
        #expect(merge.removeFromServer == mirrors)
        #expect(merge.blockedRemoveFromServer.isEmpty)
        #expect(merge.pendingRemoveFromServer.isEmpty)
    }

    @Test func aServerFeedNotKnownLocallyStillArrives() {
        // The cleanup exemption must not swallow the everyday case: a feed
        // the OTHER device added arrives normally.
        let merge = GPodderSubscriptionMerge.compute(
            local: ["https://example.org/a.xml"],
            server: ["https://example.org/a.xml", "https://example.org/new.xml"],
            prev: ["https://example.org/a.xml"],
            hiddenLocally: ["https://pinchflat.mesh/feed/1.xml"])
        #expect(merge.addLocally == ["https://example.org/new.xml"])
        #expect(merge.removeFromServer.isEmpty)
    }

    @Test func implausibleServerAnswersStayGuarded() {
        // The mass-delete brake is untouched for DERIVED removals: five feeds
        // vanishing locally without an intent stays blocked.
        let server = Set((1...10).map { "https://example.org/\($0).xml" })
        let merge = GPodderSubscriptionMerge.compute(
            local: ["https://example.org/1.xml"], server: server, prev: server)
        #expect(merge.removeFromServer.isEmpty)
        #expect(!merge.blockedRemoveFromServer.isEmpty)
    }
}

// MARK: - Aus heisst vollstaendig unsichtbar (keine Asymmetrie)

struct GPodderPremiumAsymmetryTests {
    private func show(_ url: String) -> (feedURL: String, origin: String?) { (url, nil) }

    @Test("Schalter AUS: ein gepushter Token-Feed wird weder adoptiert noch aufgeraeumt")
    func offMeansInvisibleInBothDirections() {
        let token = "https://premium.example/feed?auth=SECRETTOKEN1234567890"
        let normal = "https://example.org/a.xml"
        let tokenNorm = PodcastSubscriptions.normalizeFeedURL(token)
        let normalNorm = PodcastSubscriptions.normalizeFeedURL(normal)

        // Das Geraet mit Schalter AUS sieht den Token-Feed lokal NICHT …
        let split = GPodderVisibleSubscriptions.split([show(normal)], premiumOptIn: false)
        #expect(split.byNorm.keys.contains(normalNorm))

        // … und die SERVER-Seite wird fuer dieses Geraet ebenfalls gefiltert:
        // ohne diesen Schnitt gaelte der Feed als server-only ⇒ adoptiert,
        // und eine Runde spaeter als lokal unsichtbar ⇒ entfernt.
        let merge = GPodderSubscriptionMerge.compute(
            local: [normalNorm], server: [normalNorm], prev: [normalNorm],
            hiddenLocally: split.hiddenNorms)
        #expect(merge.addLocally.isEmpty)
        #expect(merge.removeFromServer.isEmpty)
        // Gegenprobe: MIT Schalter an ist der Feed sichtbar und reist normal.
        let on = GPodderVisibleSubscriptions.split([show(normal), show(token)], premiumOptIn: true)
        #expect(on.byNorm.keys.contains(tokenNorm))
    }
}
