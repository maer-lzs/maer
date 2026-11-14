// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
@testable import Maer

/// Tests for the pure sync decision rules (SyncRules) and the
/// multi-file time arithmetic (TrackMath). The hardened core of the app.
struct SyncRulesTests {

    // MARK: - Own echo after a dead spot (isOwnServerEcho)

    @Test("Dead spot: the server holds the own write from 35 s ago, the queue is further along, local stays")
    func deadSpotKeepsTheLocalPosition() {
        // The last write the server took: 965. Then the dead spot: the ticks
        // queued 1000 and moved lastSyncedTime on. The server's moment is
        // newer than the moment we know (the read after the write failed).
        let serverTime = 965.0
        let own = SyncRules.isOwnServerEcho(serverTime: serverTime, lastSyncedTime: 1000,
                                            flushedTime: 965, queuedTime: 1000)
        let rawRuleWouldAdopt = SyncRules.shouldAdoptServerState(
            serverTime: serverTime, serverUpdateMs: 2000, lastKnownServerUpdateMs: 1000, currentTime: 1000)
        #expect(rawRuleWouldAdopt, "the timestamps alone say foreign: that was the rewind")
        #expect(own, "the flushed witness says it is ours")
        // Server podcasts have no flushed witness; the queued write alone holds it.
        #expect(SyncRules.isOwnServerEcho(serverTime: serverTime, lastSyncedTime: 1000,
                                          flushedTime: nil, queuedTime: 1000),
                "a server that is not ahead of our queued write is ours")
        // And the reference the guard had before: lastSyncedTime alone no
        // longer matches once the queue moved it on.
        #expect(!SyncRules.isOwnServerEcho(serverTime: serverTime, lastSyncedTime: 1000))
    }

    @Test("a foreign device ahead is still taken over, even with an own queue")
    func aForeignDeviceAheadIsStillAdopted() {
        #expect(!SyncRules.isOwnServerEcho(serverTime: 1200, lastSyncedTime: 1000,
                                           flushedTime: 965, queuedTime: 1000))
        #expect(SyncRules.shouldAdoptServerState(
            serverTime: 1200, serverUpdateMs: 2000, lastKnownServerUpdateMs: 1000, currentTime: 1000))
    }

    @Test("a deliberate rewind on the other device without an own queue is taken over")
    func aForeignRewindWithoutAQueueIsAdopted() {
        #expect(!SyncRules.isOwnServerEcho(serverTime: 500, lastSyncedTime: 1000,
                                           flushedTime: 965, queuedTime: nil))
    }

    // MARK: - Device reconcile (shouldAdoptServerState)

    @Test func adoptsNewerServerEntryForward() {
        #expect(SyncRules.shouldAdoptServerState(
            serverTime: 500, serverUpdateMs: 2000, lastKnownServerUpdateMs: 1000, currentTime: 100
        ))
    }

    @Test("Deliberate rewind on another device: the newer entry wins backwards too")
    func adoptsNewerServerEntryBackward() {
        #expect(SyncRules.shouldAdoptServerState(
            serverTime: 100, serverUpdateMs: 2000, lastKnownServerUpdateMs: 1000, currentTime: 500
        ))
    }

    @Test func ignoresOlderServerEntry() {
        #expect(!SyncRules.shouldAdoptServerState(
            serverTime: 500, serverUpdateMs: 1000, lastKnownServerUpdateMs: 2000, currentTime: 100
        ))
    }

    @Test("After an own write: entry newer, but position (almost) identical")
    func ignoresOwnWriteEcho() {
        #expect(!SyncRules.shouldAdoptServerState(
            serverTime: 101, serverUpdateMs: 2000, lastKnownServerUpdateMs: 1000, currentTime: 100
        ))
    }

    @Test("Old servers without a timestamp: take over forwards only")
    func legacyServerWithoutTimestamp() {
        #expect(SyncRules.shouldAdoptServerState(
            serverTime: 500, serverUpdateMs: 0, lastKnownServerUpdateMs: 0, currentTime: 100
        ))
        #expect(!SyncRules.shouldAdoptServerState(
            serverTime: 100, serverUpdateMs: 0, lastKnownServerUpdateMs: 0, currentTime: 500
        ))
    }

    // MARK: - Queue-Flush (queuedFate)

    private func server(fraction: Double, currentTime: Double?) -> BookProgress {
        BookProgress(fraction: fraction, isFinished: false, lastUpdate: 1000, currentTime: currentTime)
    }

    @Test func dropsStaleQueuedUpdateWhenServerIsAhead() {
        #expect(SyncRules.queuedFate(
            queuedTime: 100, queuedIsFinished: false, duration: 1000,
            server: server(fraction: 0.5, currentTime: 500)
        ) == .drop)
        // Only a fraction: it counts over the queued duration.
        #expect(SyncRules.queuedFate(
            queuedTime: 100, queuedIsFinished: false, duration: 1000,
            server: server(fraction: 0.5, currentTime: nil)
        ) == .drop)
    }

    @Test func keepsQueuedUpdateWhenServerIsBehind() {
        #expect(SyncRules.queuedFate(
            queuedTime: 600, queuedIsFinished: false, duration: 1000,
            server: server(fraction: 0.5, currentTime: 500)
        ) == .send)
    }

    @Test("Status decision: finished updates are never discarded")
    func neverDropsFinishedUpdates() {
        #expect(SyncRules.queuedFate(
            queuedTime: 100, queuedIsFinished: true, duration: 1000,
            server: server(fraction: 0.9, currentTime: 900)
        ) == .send)
    }

    @Test("without a server entry the waiting stand goes out, there is nothing to overwrite")
    func sendsQueuedUpdateWithoutServerEntry() {
        #expect(SyncRules.queuedFate(
            queuedTime: 100, queuedIsFinished: false, duration: 1000, server: nil
        ) == .send)
    }

    @Test("a waiting 0 without a known duration never overrides a further server stand")
    func aQueuedZeroWithoutDurationNeverOverwrites() {
        // The server's time stands, its fraction is stale: a write without a
        // known duration sends no fraction.
        #expect(SyncRules.queuedFate(
            queuedTime: 0, queuedIsFinished: false, duration: 0,
            server: server(fraction: 0, currentTime: 3000)
        ) == .drop)
        #expect(SyncRules.queuedFate(
            queuedTime: 0, queuedIsFinished: false, duration: 1000,
            server: server(fraction: 0.1, currentTime: 3000)
        ) == .drop)
    }

    @Test("a server entry without a known position holds the waiting stand, it does not go out")
    func anUnknownServerPositionHoldsTheUpdate() {
        #expect(SyncRules.queuedFate(
            queuedTime: 100, queuedIsFinished: false, duration: 0,
            server: server(fraction: 0.9, currentTime: nil)
        ) == .hold)
        // A finished mark is a status decision and still goes out.
        #expect(SyncRules.queuedFate(
            queuedTime: 100, queuedIsFinished: true, duration: 0,
            server: server(fraction: 0.9, currentTime: nil)
        ) == .send)
    }

    // MARK: - Crash safeguard (shouldRestoreLocalPosition)

    @Test func restoresNewerLocalPosition() {
        #expect(SyncRules.shouldRestoreLocalPosition(
            savedTime: 200, savedAtMs: 2000, serverTime: 100, serverUpdateMs: 1000
        ))
    }

    @Test func ignoresOlderLocalPosition() {
        #expect(!SyncRules.shouldRestoreLocalPosition(
            savedTime: 200, savedAtMs: 1000, serverTime: 100, serverUpdateMs: 2000
        ))
    }

    @Test func ignoresLocalPositionMatchingServer() {
        #expect(!SyncRules.shouldRestoreLocalPosition(
            savedTime: 102, savedAtMs: 2000, serverTime: 100, serverUpdateMs: 1000
        ))
    }

    // MARK: - Suspicious step back (isSuspiciousDrop)

    @Test(arguments: [
        (current: 0.0, expected: true),    // hard reset → suspicious
        (current: 450.0, expected: false), // small step back → ok
        (current: 600.0, expected: false)  // forwards → ok
    ])
    func detectsSuspiciousDrop(current: Double, expected: Bool) {
        #expect(SyncRules.isSuspiciousDrop(
            currentTime: current, lastSyncedTime: 500, threshold: 120
        ) == expected)
    }
}

/// The flushed witness. Every case here is one the MEASUREMENT
/// produced on the simulator, not an invented one.
@Suite("The flushed witness carries the start only when the server says nothing better")
struct FlushedWitnessTests {

    /// The measured incident: downloaded book, crash backup deleted, cached
    /// detail without progress, server silent (offline). Without the witness
    /// the start is 0.
    @Test func serverSilentMakesOurPushTheOnlyTruth() {
        #expect(SyncRules.shouldPreferFlushedWitness(
            flushedTime: 40, flushedAtMs: 1_000, serverTime: 0, serverUpdateMs: 0))
    }

    /// Third case: the server ANSWERS with a position, but without a date
    /// on it. An answer without a date is not a statement about the
    /// position, so the witness wins even though the server's number is
    /// higher. Until 17.09.2026 this case drove the same inputs as the
    /// silent server above and bore a comment about a case nobody drove.
    @Test func answerWithoutDateDoesNotBeatTheWitness() {
        #expect(SyncRules.shouldPreferFlushedWitness(
            flushedTime: 40, flushedAtMs: 1_000, serverTime: 90, serverUpdateMs: 0))
    }

    /// The guard that matters: another device that is genuinely ahead keeps
    /// winning. Otherwise the fix would trade a null start for a rollback.
    @Test func newerForeignDeviceStillWins() {
        #expect(!SyncRules.shouldPreferFlushedWitness(
            flushedTime: 40, flushedAtMs: 1_000, serverTime: 900, serverUpdateMs: 2_000))
    }

    /// Our own echo: the server holds exactly what we pushed, dated later.
    /// Taking the witness here would be pointless, not wrong. But it must
    /// not fire, so the server stays the store of record.
    @Test func ownEchoDoesNotFire() {
        #expect(!SyncRules.shouldPreferFlushedWitness(
            flushedTime: 40, flushedAtMs: 1_000, serverTime: 40, serverUpdateMs: 1_500))
    }

    /// A witness at 0 is no witness. A fresh install must not be dragged to 0.
    @Test func zeroIsNotAWitness() {
        #expect(!SyncRules.shouldPreferFlushedWitness(
            flushedTime: 0, flushedAtMs: 9_999, serverTime: 0, serverUpdateMs: 0))
    }

    /// Import is the normal case: every existing install has NO witness. The
    /// nil branch lives at the call site, so the rule only has to stay honest
    /// about a witness that is older than the server's answer.
    @Test func olderOwnPushLosesAgainstADatedServerAnswer() {
        #expect(!SyncRules.shouldPreferFlushedWitness(
            flushedTime: 300, flushedAtMs: 1_000, serverTime: 100, serverUpdateMs: 5_000))
    }

    /// Below the tolerance nothing changes. The same 5 s the sibling rule uses.
    @Test func tinyDifferenceIsNotWorthAJump() {
        #expect(!SyncRules.shouldPreferFlushedWitness(
            flushedTime: 103, flushedAtMs: 5_000, serverTime: 100, serverUpdateMs: 1_000))
    }
}

/// The stomp window. The dangerous path needs a test case:
/// fresh session, position near 0, server clearly ahead.
@Suite("A start without an answer must write nothing to the server")
struct StompWindowTests {

    /// The reported real case: full player at 00:00, server at 8:29:33.
    /// A push from here would overwrite eight hours.
    @Test func unresolvedStartMayNotPush() {
        #expect(!SyncRules.mayPushProgress(startSourceResolved: false))
    }

    /// A server that knows nothing IS an answer. A really new book
    /// must be able to report its progress.
    @Test func answeredStartPushesAsBefore() {
        #expect(SyncRules.mayPushProgress(startSourceResolved: true))
    }
}

/// The third appearance of the frozen zero.
@Suite("Continue Listening asks the won source")
struct ContinueStartedTests {

    /// The test case: downloaded, detail progress empty, server ahead.
    /// The card MUST stand. The witness is the proof of having started.
    @Test func frozenZeroDoesNotDeleteTheCard() {
        #expect(ContinueSources.isStarted(serverSaysStarted: false,
                                          flushed: [8_000, 1_000]))
    }

    @Test func serverSaysStartedIsEnough() {
        #expect(ContinueSources.isStarted(serverSaysStarted: true, flushed: nil))
    }

    /// A tap is no begun book. The same 30 s edge as in
    /// `started(in:)`, not a second one invented.
    @Test func aTapIsNotAStartedBook() {
        #expect(!ContinueSources.isStarted(serverSaysStarted: false, flushed: [12, 1_000]))
        #expect(!ContinueSources.isStarted(serverSaysStarted: false, flushed: nil))
    }
}

struct TrackMathTests {

    private func track(index: Int, start: Double? = nil, duration: Double?) -> ABSAudioTrack {
        ABSAudioTrack(index: index, startOffset: start, duration: duration, contentUrl: "t\(index)", metadata: nil)
    }

    /// Three tracks of 100 s each, book duration 300.
    private var tracks: [ABSAudioTrack] {
        [track(index: 0, duration: 100), track(index: 1, duration: 100), track(index: 2, duration: 100)]
    }

    @Test func trackStartSumsDurations() {
        #expect(TrackMath.trackStart(index: 0, tracks: tracks, bookDuration: 300) == 0)
        #expect(TrackMath.trackStart(index: 2, tracks: tracks, bookDuration: 300) == 200)
    }

    @Test func trackStartPrefersServerOffset() {
        let t = [track(index: 0, duration: 100), track(index: 1, start: 90, duration: 100)]
        #expect(TrackMath.trackStart(index: 1, tracks: t, bookDuration: 190) == 90)
    }

    @Test func trackStartOutOfRangeReturnsBookDuration() {
        #expect(TrackMath.trackStart(index: 5, tracks: tracks, bookDuration: 300) == 300)
        #expect(TrackMath.trackStart(index: -1, tracks: tracks, bookDuration: 300) == 300)
    }

    @Test(arguments: [
        (time: 0.0, expected: 0),
        (time: 99.9, expected: 0),
        (time: 100.0, expected: 1),
        (time: 250.0, expected: 2),
        (time: 999.0, expected: 2)  // past the end of the book → last track
    ])
    func trackIndexForAbsoluteTime(time: Double, expected: Int) {
        #expect(TrackMath.trackIndex(for: time, tracks: tracks, bookDuration: 300) == expected)
    }

    @Test("Missing durations must not crash; the rest falls to the last track")
    func trackIndexWithMissingDurations() {
        let t = [track(index: 0, duration: nil), track(index: 1, duration: 100)]
        #expect(TrackMath.trackIndex(for: 50, tracks: t, bookDuration: 100) == 1)
    }
}
/// Grouping of ABS series names (see LibraryViewModel.baseSeriesName).
struct SeriesNameTests {
    @Test(arguments: [
        ("Foundation #2", "Foundation"),
        ("Foundation #2.5", "Foundation"),
        ("Foundation #1-3", "Foundation"),
        ("Reihe A #2, Reihe B #7", "Reihe A"),          // multi-series → first
        ("Krieg und Frieden, Teil 1", "Krieg und Frieden, Teil 1"), // comma inside ONE name
        ("  Foundation #2  ", "Foundation"),
    ])
    func stripsSequenceAndPicksFirstSeries(raw: String, expected: String) {
        #expect(LibraryViewModel.baseSeriesName(raw) == expected)
    }

    @Test func emptyAndNilCountAsNoSeries() {
        #expect(LibraryViewModel.baseSeriesName(nil) == nil)
        #expect(LibraryViewModel.baseSeriesName("   ") == nil)
        #expect(LibraryViewModel.baseSeriesName(" #2") == nil)
    }
}
#endif
