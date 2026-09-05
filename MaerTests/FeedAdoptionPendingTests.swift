// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// A feed the account brought that could not be followed here is marked
/// with its reason, shown, and not fetched again until the person retries,
/// signs in or removes it. One witness per reason class: dead, timeout,
/// sign-in.
struct FeedAdoptionPendingTests {
    private func suite() -> (UserDefaults, String) {
        let name = "adoption-test-\(UUID().uuidString)"
        return (UserDefaults(suiteName: name)!, name)
    }

    @Test("Merker traegt den Grund; kein zweiter Versuch, bis er geloescht ist; die alte Form wird als Anmeldung gelesen")
    func markerCarriesTheReason() {
        let (d, name) = suite()
        defer { d.removePersistentDomain(forName: name) }
        #expect(FeedAdoptionPending.Reason.from(status: 401) == .signIn)
        #expect(FeedAdoptionPending.Reason.from(status: 403) == .signIn)
        #expect(FeedAdoptionPending.Reason.from(status: 404) == .notFound)
        #expect(FeedAdoptionPending.Reason.from(status: 410) == .notFound)
        #expect(FeedAdoptionPending.Reason.from(status: 503) == .server)
        #expect(FeedAdoptionPending.demandsSignIn(status: 401) && !FeedAdoptionPending.demandsSignIn(status: nil))

        #expect(FeedAdoptionPending.shouldAttempt(feedKey: "k1", defaults: d))
        FeedAdoptionPending.mark(feedKey: "k1", feedURL: "https://example.org/a.xml", reason: .server, status: 503, defaults: d)
        FeedAdoptionPending.mark(feedKey: "k2", feedURL: "https://example.org/b.xml", reason: .timeout, defaults: d)
        #expect(!FeedAdoptionPending.shouldAttempt(feedKey: "k1", defaults: d), "no endless retry")
        #expect(FeedAdoptionPending.pending(defaults: d)["k1"] == .init(feedURL: "https://example.org/a.xml", reason: .server, status: 503))
        #expect(FeedAdoptionPending.pending(defaults: d)["k2"] == .init(feedURL: "https://example.org/b.xml", reason: .timeout, status: nil))
        // Rot-Probe: another feed is untouched.
        #expect(FeedAdoptionPending.shouldAttempt(feedKey: "k3", defaults: d))
        FeedAdoptionPending.clear(feedKey: "k1", defaults: d)
        #expect(FeedAdoptionPending.shouldAttempt(feedKey: "k1", defaults: d))
        FeedAdoptionPending.clear(feedKey: "k2", defaults: d)
        FeedAdoptionPending.clear(feedKey: "k2", defaults: d)   // idempotent
        #expect(FeedAdoptionPending.pending(defaults: d).isEmpty)
        // The first shape (address only) reads as a sign-in demand.
        d.set(["old": "https://example.org/old.xml"], forKey: AppStorageKeys.podcastFeedsNeedingSignIn)
        #expect(FeedAdoptionPending.pending(defaults: d)["old"] == .init(feedURL: "https://example.org/old.xml", reason: .signIn, status: nil))
    }

    /// The store end to end over the fetch seam, one feed per reason: a
    /// dead feed, a timeout and a sign-in demand each mark with their
    /// reason, the next adoption fetches none of them again, and a retry
    /// with a working answer follows the feed.
    @Test("Adoption: tot, Zeitlimit, 401 ⇒ je ein Merker mit Grund; kein zweiter Netzversuch; Wiederholen folgt")
    @MainActor
    func adoptionMarksEveryReasonAndRetries() async throws {
        let subs = PodcastSubscriptions.shared
        await subs.ensureLoaded()
        subs._testSetLoaded(true)
        let stem = "https://example.org/adopt-\(UUID().uuidString.prefix(8))"
        let dead = "\(stem)/dead.xml", slow = "\(stem)/slow.xml", locked = "\(stem)/locked.xml"
        let keys = [dead, slow, locked].map { PodcastSubscriptions.feedKey($0) }
        final class Counter: @unchecked Sendable { var calls: [String] = [] }
        let counter = Counter()
        var working = false
        subs._testFeedFetcher = { url in
            counter.calls.append(url.absoluteString)
            if working {
                return .show(PodcastShow(id: PodcastSubscriptions.feedKey(url.absoluteString), title: "Followed",
                                         author: nil, artworkURL: nil, description: nil,
                                         feedURL: url.absoluteString, episodes: []))
            }
            if url.absoluteString == dead { return .status(404) }
            if url.absoluteString == slow { return .failed(.timeout) }
            return .status(401)
        }
        defer {
            subs._testFeedFetcher = nil
            for key in keys { FeedAdoptionPending.clear(feedKey: key) }
            for url in [dead, slow, locked] { subs.removeMirrored(feedURL: url) }
        }
        func settle(_ condition: @MainActor () -> Bool) async throws {
            for _ in 0..<150 where !condition() {
                try await Task.sleep(nanoseconds: 20_000_000)
            }
        }

        let added = [dead, slow, locked].map { (feedURL: $0, t: 1.0) }
        subs.adoptCloudSubscriptions(added: added, removed: [])
        try await settle { keys.allSatisfy { subs.feedsNotFollowed[$0] != nil } }
        #expect(subs.feedsNotFollowed[keys[0]]?.reason == .notFound)
        #expect(subs.feedsNotFollowed[keys[1]]?.reason == .timeout)
        #expect(subs.feedsNotFollowed[keys[2]]?.reason == .signIn)
        #expect(counter.calls.count == 3)

        // The next reconcile offers all three again: no fetch.
        subs.adoptCloudSubscriptions(added: added, removed: [])
        try await Task.sleep(nanoseconds: 300_000_000)
        #expect(counter.calls.count == 3, "a marked feed is not fetched again")

        // Retry with a working feed: one attempt, followed, marker gone.
        working = true
        subs.retryAdoption(feedKey: keys[0])
        try await settle { subs.shows.contains { $0.feedURL == dead } }
        #expect(counter.calls.count == 4)
        #expect(subs.feedsNotFollowed[keys[0]] == nil)
        // The others stay marked until their own retry.
        #expect(subs.feedsNotFollowed[keys[1]] != nil && subs.feedsNotFollowed[keys[2]] != nil)
    }
}
#endif
