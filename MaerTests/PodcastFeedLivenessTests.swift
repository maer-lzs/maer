// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// Offering something undeliverable is a defect. And so is an empty row.
/// The health signal is therefore an ORDER, never a filter.
struct PodcastFeedLivenessTests {

    @Test("Silence is not bad news")
    func silenceIsUsable() {
        #expect(PodcastFeedLiveness.verdict(nil) == .usable)
        #expect(PodcastFeedLiveness.verdict(FeedLiveness()) == .usable)
        #expect(PodcastFeedLiveness.verdict(FeedLiveness(dead: 0, lastHttpStatus: 200)) == .usable)
    }

    @Test("given up means given up")
    func goneIsGone() {
        #expect(PodcastFeedLiveness.verdict(FeedLiveness(dead: 1)) == .gone)
        // 0 = never reached.
        #expect(PodcastFeedLiveness.verdict(FeedLiveness(dead: 0, lastHttpStatus: 0)) == .gone)
        #expect(PodcastFeedLiveness.verdict(FeedLiveness(dead: 0, lastHttpStatus: 404)) == .gone)
        #expect(PodcastFeedLiveness.verdict(FeedLiveness(dead: 0, lastHttpStatus: 500)) == .gone)
        // A redirect is something the fetch follows, not a verdict.
        #expect(PodcastFeedLiveness.verdict(FeedLiveness(dead: 0, lastHttpStatus: 301)) == .usable)
    }

    @Test("stumbling is not dead")
    func stumblingIsOnlyDoubtful() {
        #expect(PodcastFeedLiveness.verdict(
            FeedLiveness(dead: 0, lastHttpStatus: 200, parseErrors: 3)) == .doubtful)
        #expect(PodcastFeedLiveness.verdict(
            FeedLiveness(dead: 0, lastHttpStatus: 200, crawlErrors: 2)) == .doubtful)
    }

    @Test("reorder, never discard, and the ranking stays within the group")
    func reordersWithoutDropping() {
        struct Row: Equatable { let name: String; let liveness: FeedLiveness? }
        let rows = [
            Row(name: "tot", liveness: FeedLiveness(dead: 1)),
            Row(name: "gut1", liveness: FeedLiveness(dead: 0, lastHttpStatus: 200)),
            Row(name: "unbekannt", liveness: nil),
            Row(name: "stolpernd", liveness: FeedLiveness(dead: 0, lastHttpStatus: 200, parseErrors: 1)),
            Row(name: "gut2", liveness: FeedLiveness(dead: 0, lastHttpStatus: 200)),
        ]
        let out = PodcastFeedLiveness.demotingDoubtful(rows) { $0.liveness }
        #expect(out.map(\.name) == ["gut1", "unbekannt", "gut2", "stolpernd", "tot"])
        // Nothing may vanish. Content before purity.
        #expect(out.count == rows.count)
        #expect(Set(out.map(\.name)) == Set(rows.map(\.name)))
    }

    @Test("a widespread outage empties no row")
    func anOutageCannotEmptyTheRow() {
        struct Row: Equatable { let name: String; let liveness: FeedLiveness? }
        // Every single one condemned: the row still stands, only reordered.
        let rows = (1...5).map { Row(name: "\($0)", liveness: FeedLiveness(dead: 1)) }
        let out = PodcastFeedLiveness.demotingDoubtful(rows) { $0.liveness }
        #expect(out.count == 5)
        #expect(out.map(\.name) == rows.map(\.name), "gleiche Verdikte behalten die Rangfolge")
    }
}
#endif
