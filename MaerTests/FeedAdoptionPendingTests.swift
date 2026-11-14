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

    @Test("every offered subscription names its outcome: followed, twin, marked with a reason", .needsTheSources)
    func eachOfferSaysItsOutcome() throws {
        #expect(FeedAdoptionPending.outcome(ok: true, held: true, reason: nil) == "followed")
        #expect(FeedAdoptionPending.outcome(ok: true, held: false, reason: nil) == "twin",
                "yes without holding it is the free twin of a held premium feed")
        #expect(FeedAdoptionPending.outcome(ok: false, held: false, reason: .timeout) == "marked reason=timeout")
        #expect(FeedAdoptionPending.outcome(ok: false, held: false, reason: nil) == "notAsked",
                "not followed and not marked is the follow that was not asked")
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let store = try String(contentsOf: root.appendingPathComponent("Sources/Providers/PodcastSubscriptions.swift"), encoding: .utf8)
        #expect(store.contains("ok=\\(ok) outcome=\\(outcome, privacy: .public)"), "the adoption line names the outcome")
        #expect(store.contains("not followed reason=\\(reason, privacy: .public)"), "a skip names the mark's reason")
    }

    @Test("marker carries the reason; no second attempt until it is cleared; the old form is read as a sign-in")
    func markerCarriesTheReason() {
        let (d, name) = suite()
        defer { d.removePersistentDomain(forName: name) }
        #expect(FeedAdoptionPending.Reason.from(status: 401) == .signIn)
        #expect(FeedAdoptionPending.Reason.from(status: 403) == .signIn)
        #expect(FeedAdoptionPending.Reason.from(status: 404) == .notFound)
        #expect(FeedAdoptionPending.Reason.from(status: 410) == .notFound)
        #expect(FeedAdoptionPending.Reason.from(status: 503) == .server)

        #expect(FeedAdoptionPending.shouldAttempt(feedKey: "k1", defaults: d))
        FeedAdoptionPending.mark(feedKey: "k1", feedURL: "https://example.org/a.xml", reason: .server, status: 503, defaults: d)
        FeedAdoptionPending.mark(feedKey: "k2", feedURL: "https://example.org/b.xml", reason: .timeout, defaults: d)
        #expect(!FeedAdoptionPending.shouldAttempt(feedKey: "k1", defaults: d), "no endless retry")
        #expect(FeedAdoptionPending.pending(defaults: d)["k1"] == .init(feedURL: "https://example.org/a.xml", reason: .server, status: 503))
        #expect(FeedAdoptionPending.pending(defaults: d)["k2"] == .init(feedURL: "https://example.org/b.xml", reason: .timeout, status: nil))
        // Red probe: another feed is untouched.
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

    /// Dismissing is local: the marker answers ONE account statement (its
    /// stamp), keeps the adoption quiet for it, and a newer statement (the
    /// person subscribed again elsewhere) beats it.
    @Test("Dismissing is local: marker with a stamp, a newer statement brings the feed back")
    func dismissedMarkerAnswersOneStatement() {
        let (d, name) = suite()
        defer { d.removePersistentDomain(forName: name) }
        FeedAdoptionPending.mark(feedKey: "k", feedURL: "https://example.org/k.xml", reason: .dismissed,
                                 statementT: 5000, defaults: d)
        #expect(FeedAdoptionPending.pending(defaults: d)["k"]?.reason == .dismissed)
        #expect(FeedAdoptionPending.pending(defaults: d)["k"]?.statementT == 5000)
        #expect(!FeedAdoptionPending.shouldAttempt(feedKey: "k", statementT: 5000, defaults: d), "the same statement stays quiet")
        #expect(!FeedAdoptionPending.shouldAttempt(feedKey: "k", statementT: 4000, defaults: d), "an older one too")
        #expect(FeedAdoptionPending.shouldAttempt(feedKey: "k", statementT: 6000, defaults: d), "a newer statement beats the marker")
        // Red probe: a marker without a stamp (a failed fetch) never expires by statement.
        FeedAdoptionPending.mark(feedKey: "f", feedURL: "https://example.org/f.xml", reason: .timeout, defaults: d)
        #expect(!FeedAdoptionPending.shouldAttempt(feedKey: "f", statementT: 9000, defaults: d))
    }

    /// The store end to end: dismissing writes NO tombstone into the
    /// account and offers nothing on the next reconcile; a newer statement
    /// is fetched again.
    @Test("Dismissing writes no tombstone; next reconcile offers nothing; a newer statement is fetched")
    @MainActor
    func dismissIsLocalAndANewerStatementReturns() async throws {
        let subs = PodcastSubscriptions.shared
        await subs.ensureLoaded()
        subs._testSetLoaded(true)
        let feedURL = "https://example.org/dismiss-\(UUID().uuidString.prefix(8))/feed.xml"
        let key = PodcastIdentity.feedKey(feedURL)
        // Unchecked because the subscriptions call their fetcher seam on the
        // main actor only, where the witness reads the count.
        final class Counter: @unchecked Sendable { var calls = 0 }
        let counter = Counter()
        subs._testFeedFetcher = { _ in counter.calls += 1; return .status(404) }
        let removedBefore = PodcastSubscriptions.userRemovedFeeds()
        defer {
            subs._testFeedFetcher = nil
            FeedAdoptionPending.clear(feedKey: key)
        }
        func settle(_ condition: @MainActor () -> Bool) async throws {
            for _ in 0..<150 where !condition() { try await Task.sleep(nanoseconds: 20_000_000) }
        }
        subs.adoptCloudSubscriptions(added: [(feedURL: feedURL, t: 1000)], removed: [])
        try await settle { subs.feedsNotFollowed[key] != nil }
        #expect(counter.calls == 1)
        subs.removeNotFollowed(feedKey: key)
        #expect(subs.feedsNotFollowed[key]?.reason == .dismissed)
        // No tombstone, no user-removed mark: the account keeps the show.
        #expect(PodcastSubscriptions.userRemovedFeeds() == removedBefore)
        subs.adoptCloudSubscriptions(added: [(feedURL: feedURL, t: 1000)], removed: [])
        try await Task.sleep(nanoseconds: 300_000_000)
        #expect(counter.calls == 1, "the dismissed statement is not fetched again")
        // The person subscribes again elsewhere: a newer statement is fetched.
        subs.adoptCloudSubscriptions(added: [(feedURL: feedURL, t: 2000)], removed: [])
        try await settle { counter.calls == 2 }
        #expect(counter.calls == 2, "a newer statement beats the dismissal")
    }

    /// The store end to end over the fetch seam, one feed per reason: a
    /// dead feed, a timeout and a sign-in demand each mark with their
    /// reason, the next adoption fetches none of them again, and a retry
    /// with a working answer follows the feed.
    @Test("Adoption: dead, timeout, 401 ⇒ one marker each with a reason; no second network attempt; retrying follows")
    @MainActor
    func adoptionMarksEveryReasonAndRetries() async throws {
        let subs = PodcastSubscriptions.shared
        await subs.ensureLoaded()
        subs._testSetLoaded(true)
        let stem = "https://example.org/adopt-\(UUID().uuidString.prefix(8))"
        let dead = "\(stem)/dead.xml", slow = "\(stem)/slow.xml", locked = "\(stem)/locked.xml"
        let keys = [dead, slow, locked].map { PodcastIdentity.feedKey($0) }
        // Unchecked because the subscriptions call their fetcher seam on the
        // main actor only, where the witness reads the calls.
        final class Counter: @unchecked Sendable { var calls: [String] = [] }
        let counter = Counter()
        var working = false
        subs._testFeedFetcher = { url in
            counter.calls.append(url.absoluteString)
            if working {
                return .show(PodcastShow(id: PodcastIdentity.feedKey(url.absoluteString), title: "Followed",
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

    @Test("A new link for the same feed does not withdraw the subscription just stated", .needsTheSources)
    func theSameFeedUnderANewLinkKeepsItsSubscription() throws {
        let old = "https://premium.example/feed.xml"
        #expect(!PodcastSubscriptions.withdrawsOldAddress(oldFeedURL: old, newURL: old), "the same link")
        #expect(!PodcastSubscriptions.withdrawsOldAddress(oldFeedURL: old, newURL: "HTTPS://Premium.Example/feed.xml"),
                "the same link in capitals")
        #expect(!PodcastSubscriptions.withdrawsOldAddress(oldFeedURL: old, newURL: old + "?utm_source=mail"),
                "the same link with a tracking parameter")
        #expect(PodcastSubscriptions.withdrawsOldAddress(oldFeedURL: old, newURL: "https://premium.example/other.xml"),
                "another feed")
        #expect(PodcastSubscriptions.withdrawsOldAddress(oldFeedURL: old, newURL: old + "?token=neu"),
                "an identity parameter makes another feed")
        // Wiring: the withdrawal in replaceAdoption asks the rule first.
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let text = try String(contentsOf: root.appendingPathComponent("Sources/Providers/PodcastSubscriptions.swift"),
                              encoding: .utf8)
        let start = try #require(text.range(of: "func replaceAdoption(feedKey:"))
        let body = text[start.upperBound...].prefix(1_200)
        let rule = try #require(body.range(of: "Self.withdrawsOldAddress(oldFeedURL: entry.feedURL, newURL: newURL)"),
                                "replaceAdoption does not ask the rule")
        let withdrawal = try #require(body.range(of: "Self.stateSubscription(entry.feedURL, subscribed: false)"))
        #expect(rule.lowerBound < withdrawal.lowerBound)
    }
}
#endif
