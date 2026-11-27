// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// The switch "premium feeds sync" covers the episode actions too: with it
/// off, a token feed's address never leaves in an action.
struct GPodderTokenActionsTests {
    static let premiumFeed = "https://premium.example/feed.xml?token=abc123"
    static let plain = "https://example.org/feed.xml"

    @Test("the rule: a token feed carries actions only with the switch on; every other feed always")
    func rule() {
        #expect(!GPodderVisibleSubscriptions.mayCarryActions(feedURL: Self.premiumFeed, premiumOptIn: false))
        #expect(GPodderVisibleSubscriptions.mayCarryActions(feedURL: Self.premiumFeed, premiumOptIn: true))
        #expect(GPodderVisibleSubscriptions.mayCarryActions(feedURL: Self.plain, premiumOptIn: false))
    }

    @Test("Fence: both ways of the episode actions ask the rule before an address leaves", .needsTheSources)
    func bothWays() throws {
        let sync = SyncContractFenceTests.stripped(try String(contentsOf: SourceTree.root.appendingPathComponent("Sources/Networking/GPodderSync.swift"), encoding: .utf8))
        let single = try #require(sync.range(of: "private func pushSingle("))
        #expect(sync[single.upperBound...].prefix(600).contains("GPodderVisibleSubscriptions.mayCarryActions(feedURL: found.show.feedURL"))
        let batch = try #require(sync.range(of: "let candidates: [(feed: String, audioURL: String, guid: String, duration: Double)] ="))
        #expect(sync[batch.lowerBound...].prefix(400).contains("GPodderVisibleSubscriptions.mayCarryActions(feedURL: show.feedURL"))
    }

    @Test("the sentence that a token feed is never synced stands only while it is true, with the switch off")
    func sentence() {
        #expect(GPodderVisibleSubscriptions.saysNeverSynced(premiumOptIn: false))
        #expect(!GPodderVisibleSubscriptions.saysNeverSynced(premiumOptIn: true))
    }

    @Test("Fence: both places of the sentence ask the switch", .needsTheSources)
    func sentencePlaces() throws {
        for path in ["Sources/Views/PodcastSourceView.swift", "Sources/Views/Podcasts/PremiumFeedsSection.swift"] {
            let view = SyncContractFenceTests.stripped(try String(contentsOf: SourceTree.root.appendingPathComponent(path), encoding: .utf8))
            let sentence = try #require(view.range(of: "never synced to a gpodder server"), "\(path)")
            #expect(view[..<sentence.lowerBound].suffix(500).contains("GPodderVisibleSubscriptions.saysNeverSynced(premiumOptIn:"), "\(path) says it whatever the switch")
        }
    }
}
#endif
