// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// A subscribe tap that subscribed nothing forgets nothing (`SubscribeTap`).
/// Before, the badge discarded the failure of both branches and then always
/// forgot the remembered episodes of the feed: a tap without a network left
/// the positions of episodes heard without a subscription without names.
@MainActor
struct SubscribeTapTests {
    private func show(feedURL: String) -> PodcastShow {
        PodcastShow(id: "tap-\(UUID().uuidString)", title: "Heard Show", author: "Host",
                    artworkURL: nil, description: nil, feedURL: feedURL,
                    episodes: [PodcastEpisode(guid: "rss:tap:\(UUID().uuidString)", title: "Ep",
                                              audioURL: "https://x.example/ep.mp3", pubDate: 1_700_000_000_000,
                                              duration: 1800, description: nil, imageURL: nil, chaptersURL: nil)])
    }

    /// A subscription stands and takes the show over; a tap that was set out
    /// or failed subscribed nothing.
    private func standing(_ tap: SubscribeTap) -> Bool { tap == .subscribed || tap == .heldOnServer }

    @Test("jede Antwort der zwei Zweige: nur ein stehendes Abo uebernimmt die Sendung")
    func onlyAStandingSubscriptionTakesTheShowOver() {
        #expect(SubscribeTap.local(.subscribed) == .subscribed)
        #expect(SubscribeTap.local(.subscribedUnchecked) == .subscribed)
        #expect(SubscribeTap.local(.onServer(title: "T")) == .heldOnServer)
        #expect(SubscribeTap.local(.setOut) == .setOut)
        #expect(!standing(SubscribeTap.local(.notSubscribed)), "a failed local subscribe takes the show over")
        #expect(SubscribeTap.server(failure: nil) == .subscribed)
        #expect(SubscribeTap.server(failure: "Feed: timeout") == .failed(sentence: "Feed: timeout"))
    }

    /// The tap's end on the remembered episodes, per answer: the browsed
    /// half and the kept rows stay unless a subscription stands, and a
    /// failure is said.
    @Test("ein gescheiterter oder ausgesetzter Tipp behaelt die gemerkten Folgen und sagt es, ein Abo raeumt sie")
    func aFailedTapKeepsTheHeardEpisodes() {
        let suite = "tap-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let subs = PodcastSubscriptions.shared
        defer { subs.tapFailureNotice = nil; subs.serverUnreadNotice = false }

        for tap in [SubscribeTap.failed(sentence: "The feed could not be loaded."), .setOut,
                    .subscribed, .heldOnServer] {
            let store = BrowsedEpisodes()
            let heard = show(feedURL: "https://x.example/feed-\(UUID().uuidString)")
            let guid = heard.episodes[0].guid
            store.remember(show: heard)
            store.keepListened(guid: guid, defaults: defaults)
            #expect(store.listened(guid: guid, defaults: defaults) != nil, "the precondition: heard and kept")
            subs.tapFailureNotice = nil
            subs.serverUnreadNotice = false

            PodcastSubscribeBadge.settle(tap, feedURL: heard.feedURL, browsed: store, defaults: defaults)

            let kept = store.listened(guid: guid, defaults: defaults) != nil
            let browsed = store.episode(guid: guid) != nil
            if standing(tap) {
                #expect(!kept && !browsed, "a standing subscription leaves the browsed halves: \(tap)")
            } else {
                #expect(kept, "a tap that subscribed nothing forgot the kept row: \(tap)")
                #expect(browsed, "a tap that subscribed nothing forgot the browsed episode: \(tap)")
            }
            switch tap {
            case .failed(let sentence): #expect(subs.tapFailureNotice == sentence, "the failure is not said")
            case .setOut: #expect(subs.serverUnreadNotice, "the set-out tap is not said")
            case .subscribed, .heldOnServer:
                #expect(subs.tapFailureNotice == nil && !subs.serverUnreadNotice, "a subscription says a failure")
            }
        }
    }

    /// The badge's one way: both branches hand their answer to `settle`, no
    /// forgetting outside it, no discarded server answer.
    @Test("der Abo-Weg des Abzeichens vergisst nur in settle und verwirft keine Antwort", .needsTheSources)
    func theBadgeForgetsOnlyInSettle() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let text = try String(contentsOf: root.appendingPathComponent("Sources/Views/Podcasts/PodcastComponents.swift"),
                              encoding: .utf8)
        let squeezed = SyncContractFenceTests.stripped(text).split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        #expect(!squeezed.contains("_ = await ABSPodcastProvider.shared.subscribeOnServer"),
                "the server branch discards its answer again")
        let forgets = squeezed.components(separatedBy: ".forgetListened(").count - 1
        #expect(forgets == 1, "forgetListened stands outside settle: \(forgets)")
        let settleBody = squeezed.components(separatedBy: "static func settle(").dropFirst().first ?? ""
        #expect(settleBody.contains("case .subscribed, .heldOnServer: PodcastRecommendationsStore.shared.remove"),
                "the forgetting is not bound to a standing subscription")
    }
}
#endif
