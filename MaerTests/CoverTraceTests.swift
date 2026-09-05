// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// The cover chain's self-report. The measurement it has to make possible
/// is "the same tile asks for the same picture again", so the tally is
/// what these cases are really about; the line is only its carrier.
struct CoverTraceTests {
    private let cover = URL(string: "https://archive.org/services/img/anItem")!
    private let other = URL(string: "https://archive.org/services/img/another")!

    @Test func lineNamesPotOutcomeAndAttempt() {
        let line = CoverTrace.line(pot: .thumbnail, outcome: .hit, attempt: 3, url: cover)
        #expect(line == "COVER pot=thumbnail outcome=hit attempt=3 archive.org/services/img/anItem")
    }

    /// E84: the query carries the server's token; the line never does.
    @Test func lineDropsTheQuery() {
        let signed = URL(string: "https://music.example/rest/getCoverArt.view?u=admin&t=abc&s=salt&v=1.16.1&c=Maer")!
        let line = CoverTrace.line(pot: .network, outcome: .hit, attempt: 1, url: signed)
        #expect(line == "COVER pot=network outcome=hit attempt=1 music.example/rest/getCoverArt.view")
        #expect(!line.contains("abc") && !line.contains("salt") && !line.contains("admin"))
    }

    /// The vocabulary is read by a human off a device log, so every term
    /// is pinned. A renamed case that silently changes the log would make
    /// two measurement runs incomparable.
    @Test func vocabularyIsPinned() {
        #expect(CoverTrace.Pot.memo.rawValue == "memo")
        #expect(CoverTrace.Pot.thumbnail.rawValue == "thumbnail")
        #expect(CoverTrace.Pot.full.rawValue == "full")
        #expect(CoverTrace.Pot.network.rawValue == "network")
        #expect(CoverTrace.Outcome.hit.rawValue == "hit")
        #expect(CoverTrace.Outcome.offline.rawValue == "offline")
        #expect(CoverTrace.Outcome.transport.rawValue == "transport")
        #expect(CoverTrace.Outcome.servicePlaceholder.rawValue == "service-placeholder")
        #expect(CoverTrace.Outcome.undecodable.rawValue == "undecodable")
    }

    /// The address goes last: a truncated log line must still carry the
    /// verdict.
    @Test func verdictStandsBeforeTheAddress() {
        let line = CoverTrace.line(pot: .network, outcome: .transport, attempt: 1, url: cover)
        let verdictEnd = line.range(of: "attempt=1")!.upperBound
        let addressStart = line.range(of: "archive.org/")!.lowerBound
        #expect(verdictEnd < addressStart)
    }

    @Test func firstSightIsAttemptOne() {
        var counter = CoverTrace.Counter()
        #expect(counter.next(for: cover) == 1)
    }

    /// The measuring case. A tally that answered "1" again would report a
    /// reload as a cold first visit, which is exactly the confusion the
    /// instrument exists to end.
    @Test func askingTheSameAddressAgainCountsUp() {
        var counter = CoverTrace.Counter()
        #expect(counter.next(for: cover) == 1)
        #expect(counter.next(for: cover) == 2)
        #expect(counter.next(for: cover) == 3)
    }

    /// The red probe from the other side: two addresses must not share a
    /// tally, otherwise a long scroll over distinct covers would look
    /// like one tile reloading forever.
    @Test func distinctAddressesCountSeparately() {
        var counter = CoverTrace.Counter()
        #expect(counter.next(for: cover) == 1)
        #expect(counter.next(for: other) == 1)
        #expect(counter.next(for: cover) == 2)
        #expect(counter.next(for: other) == 2)
    }

    /// A hit must not stop the counting. If the tally were cleared on
    /// success it would go blind at the moment the chain starts working,
    /// and the repeat case would never be visible again.
    @Test func countingSurvivesAHit() {
        var counter = CoverTrace.Counter()
        _ = counter.next(for: cover)
        let second = counter.next(for: cover)
        #expect(second == 2)
        #expect(counter.trackedAddresses == 1)
    }

    @Test func resetForgetsEverything() {
        var counter = CoverTrace.Counter()
        _ = counter.next(for: cover)
        _ = counter.next(for: other)
        #expect(counter.trackedAddresses == 2)
        counter.reset()
        #expect(counter.trackedAddresses == 0)
        #expect(counter.next(for: cover) == 1)
    }

    /// The ceiling exists so a far scroll cannot grow the tally without
    /// bound. It sits above what the image caches themselves hold, so a
    /// trim can never cut a measurement that the caches could still serve.
    @Test func ceilingSitsAboveTheThumbnailCapacity() {
        #expect(CoverTrace.addressCeiling > 240)
    }
}
#endif
