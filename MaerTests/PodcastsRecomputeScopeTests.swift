// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// The Podcasts tab fills its sections in `.task(id: recomputeToken)`; the
/// token must move when the subscription list moves, whoever moved it: a
/// subscription adopted from the account in the background takes the same
/// path as one the person subscribed by hand. Without a move the grid stands
/// until the next app start.
struct PodcastsRecomputeScopeTests {
    @Test("Adoption aus dem Konto bewegt den Recompute-Token wie ein Abonnieren von Hand; ohne Aenderung bleibt er")
    @MainActor
    func adoptionMovesTheToken() async throws {
        let subs = PodcastSubscriptions.shared
        await subs.ensureLoaded()
        subs._testSetLoaded(true)
        let scope = PodcastsRecomputeScope.shared
        let feedURL = "https://example.org/recompute-\(UUID().uuidString.prefix(8))/feed.xml"
        subs._testFeedFetcher = { url in
            .show(PodcastShow(id: PodcastSubscriptions.feedKey(url.absoluteString), title: "Adopted",
                              author: nil, artworkURL: nil, description: nil,
                              feedURL: url.absoluteString, episodes: []))
        }
        defer {
            subs._testFeedFetcher = nil
            subs.removeMirrored(feedURL: feedURL)
        }
        func settle(_ condition: @MainActor () -> Bool) async throws {
            for _ in 0..<100 where !condition() {
                try await Task.sleep(nanoseconds: 20_000_000)
            }
        }
        // Rot-Probe: no change, no move (a settled token stays).
        try await Task.sleep(nanoseconds: 50_000_000)
        let before = scope.token
        try await Task.sleep(nanoseconds: 100_000_000)
        #expect(scope.token == before, "a token without a change must stand")

        subs.adoptCloudSubscriptions(added: [(feedURL: feedURL, t: 1)], removed: [])
        try await settle { subs.shows.contains { $0.feedURL == feedURL } }
        try await settle { scope.token != before }
        #expect(scope.token != before, "an adopted subscription must move the token")

        // And the way back: the show leaves, the token moves again.
        let held = scope.token
        subs.removeMirrored(feedURL: feedURL)
        try await settle { scope.token != held }
        #expect(scope.token != held)
    }
}
#endif
