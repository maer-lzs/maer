// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// Ein Feed, dessen Adoption an der Anmeldung scheitert, wird sichtbar
/// gemerkt und nicht endlos neu versucht: erst eine gespeicherte Anmeldung
/// oder das Entfernen durch die Person oeffnet den Weg wieder.
struct FeedSignInPendingTests {
    private func suite() -> (UserDefaults, String) {
        let name = "signin-test-\(UUID().uuidString)"
        return (UserDefaults(suiteName: name)!, name)
    }

    @Test("401 bei der Adoption merkt den Feed; kein zweiter Versuch, bis eine Anmeldung da ist")
    func signInDemandIsRememberedAndNotRetried() {
        let (d, name) = suite()
        defer { d.removePersistentDomain(forName: name) }
        #expect(FeedSignInPending.demandsSignIn(status: 401))
        #expect(FeedSignInPending.demandsSignIn(status: 403))
        #expect(!FeedSignInPending.demandsSignIn(status: 404) && !FeedSignInPending.demandsSignIn(status: nil))

        #expect(FeedSignInPending.shouldAttempt(feedKey: "k1", defaults: d))
        FeedSignInPending.mark(feedKey: "k1", feedURL: "https://example.org/private.xml", defaults: d)
        #expect(!FeedSignInPending.shouldAttempt(feedKey: "k1", defaults: d), "no endless retry")
        #expect(FeedSignInPending.pending(defaults: d) == ["k1": "https://example.org/private.xml"])
        // Rot-Probe: another feed is untouched.
        #expect(FeedSignInPending.shouldAttempt(feedKey: "k2", defaults: d))

        // A saved login reopens the way, once.
        FeedSignInPending.clear(feedKey: "k1", defaults: d)
        #expect(FeedSignInPending.shouldAttempt(feedKey: "k1", defaults: d))
        #expect(FeedSignInPending.pending(defaults: d).isEmpty)
        // Second run is a no-op (import class: idempotent).
        FeedSignInPending.clear(feedKey: "k1", defaults: d)
        #expect(FeedSignInPending.pending(defaults: d).isEmpty)
    }

    /// The store end to end over the fetch seam: a 401 during adoption
    /// marks the feed and makes it visible, the next adoption does not
    /// fetch it again, and the retry after a saved login fetches once and
    /// subscribes.
    @Test("Adoption: 401 ⇒ Platzhalter, kein zweiter Netzversuch, nach Anmeldung ein Versuch und Erfolg")
    @MainActor
    func adoptionMarksSkipsAndRetries() async throws {
        let subs = PodcastSubscriptions.shared
        await subs.ensureLoaded()
        subs._testSetLoaded(true)
        let feedURL = "https://example.org/signin-\(UUID().uuidString.prefix(8))/feed.xml"
        let key = PodcastSubscriptions.feedKey(feedURL)
        final class Counter: @unchecked Sendable { var calls = 0 }
        let counter = Counter()
        var demandSignIn = true
        subs._testFeedFetcher = { url in
            counter.calls += 1
            if demandSignIn { return .status(401) }
            return .show(PodcastShow(id: PodcastSubscriptions.feedKey(url.absoluteString),
                                     title: "Private", author: nil, artworkURL: nil,
                                     description: nil, feedURL: url.absoluteString, episodes: []))
        }
        defer {
            subs._testFeedFetcher = nil
            FeedSignInPending.clear(feedKey: key)
            subs.removeMirrored(feedURL: feedURL)
        }

        func settle(_ condition: @MainActor () -> Bool) async throws {
            for _ in 0..<100 where !condition() {
                try await Task.sleep(nanoseconds: 20_000_000)
            }
        }

        subs.adoptCloudSubscriptions(added: [(feedURL: feedURL, t: 1)], removed: [])
        try await settle { subs.feedsNeedingSignIn[key] != nil }
        #expect(subs.feedsNeedingSignIn[key] == feedURL, "401 ⇒ the feed is visibly waiting for a login")
        #expect(counter.calls == 1)
        #expect(!subs.shows.contains { $0.feedURL == feedURL })

        // The next reconcile hands the same statement over again: no fetch.
        subs.adoptCloudSubscriptions(added: [(feedURL: feedURL, t: 1)], removed: [])
        try await Task.sleep(nanoseconds: 300_000_000)
        #expect(counter.calls == 1, "a marked feed is not fetched again")

        // A saved login: exactly one fresh attempt, and it subscribes.
        demandSignIn = false
        subs.retrySignIn(feedKey: key)
        try await settle { subs.shows.contains { $0.feedURL == feedURL } }
        #expect(counter.calls == 2)
        #expect(subs.feedsNeedingSignIn[key] == nil)
        #expect(subs.shows.contains { $0.feedURL == feedURL })
        // Rot-Probe of the no-op: an unmarked key triggers nothing.
        subs.retrySignIn(feedKey: key)
        try await Task.sleep(nanoseconds: 100_000_000)
        #expect(counter.calls == 2)
    }
}
#endif
