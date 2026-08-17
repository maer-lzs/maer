// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
@testable import ABSPlayer

/// Tests für die reinen Sync-Entscheidungsregeln (SyncRules) und die
/// Multi-File-Zeitrechnung (TrackMath) — der gehärtete Kern der App.
struct SyncRulesTests {

    // MARK: - Geräte-Abgleich (shouldAdoptServerState)

    @Test func adoptsNewerServerEntryForward() {
        #expect(SyncRules.shouldAdoptServerState(
            serverTime: 500, serverUpdateMs: 2000, lastKnownServerUpdateMs: 1000, currentTime: 100
        ))
    }

    @Test("Bewusstes Zurückspulen auf anderem Gerät: neuerer Eintrag gewinnt auch rückwärts")
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

    @Test("Nach eigenem Write: Eintrag neuer, Position aber (fast) identisch")
    func ignoresOwnWriteEcho() {
        #expect(!SyncRules.shouldAdoptServerState(
            serverTime: 101, serverUpdateMs: 2000, lastKnownServerUpdateMs: 1000, currentTime: 100
        ))
    }

    @Test("Alte Server ohne Zeitstempel: nur vorwärts übernehmen")
    func legacyServerWithoutTimestamp() {
        #expect(SyncRules.shouldAdoptServerState(
            serverTime: 500, serverUpdateMs: 0, lastKnownServerUpdateMs: 0, currentTime: 100
        ))
        #expect(!SyncRules.shouldAdoptServerState(
            serverTime: 100, serverUpdateMs: 0, lastKnownServerUpdateMs: 0, currentTime: 500
        ))
    }

    // MARK: - Queue-Flush (shouldDropQueuedUpdate)

    @Test func dropsStaleQueuedUpdateWhenServerIsAhead() {
        #expect(SyncRules.shouldDropQueuedUpdate(
            queuedTime: 100, queuedIsFinished: false, duration: 1000, serverFraction: 0.5
        ))
    }

    @Test func keepsQueuedUpdateWhenServerIsBehind() {
        #expect(!SyncRules.shouldDropQueuedUpdate(
            queuedTime: 600, queuedIsFinished: false, duration: 1000, serverFraction: 0.5
        ))
    }

    @Test("Statusentscheidung: finished-Updates werden nie verworfen")
    func neverDropsFinishedUpdates() {
        #expect(!SyncRules.shouldDropQueuedUpdate(
            queuedTime: 100, queuedIsFinished: true, duration: 1000, serverFraction: 0.9
        ))
    }

    @Test func keepsQueuedUpdateWithoutServerEntryOrDuration() {
        #expect(!SyncRules.shouldDropQueuedUpdate(
            queuedTime: 100, queuedIsFinished: false, duration: 1000, serverFraction: nil
        ))
        #expect(!SyncRules.shouldDropQueuedUpdate(
            queuedTime: 100, queuedIsFinished: false, duration: 0, serverFraction: 0.9
        ))
    }

    // MARK: - Crash-Sicherung (shouldRestoreLocalPosition)

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

    // MARK: - Verdächtiger Rückschritt (isSuspiciousDrop)

    @Test(arguments: [
        (current: 0.0, expected: true),    // harter Reset → verdächtig
        (current: 450.0, expected: false), // kleiner Rückschritt → ok
        (current: 600.0, expected: false)  // vorwärts → ok
    ])
    func detectsSuspiciousDrop(current: Double, expected: Bool) {
        #expect(SyncRules.isSuspiciousDrop(
            currentTime: current, lastSyncedTime: 500, threshold: 120
        ) == expected)
    }
}

/// c59e96e — the flushed witness. Every case here is one the MEASUREMENT
/// produced on the simulator, not an invented one.
@Suite("Der geflusht-Zeuge traegt den Start nur, wenn der Server nichts Besseres sagt")
struct FlushedWitnessTests {

    /// The measured incident: downloaded book, crash backup deleted, cached
    /// detail without progress, server silent (offline). Without the witness
    /// the start is 0.
    @Test func serverSilentMakesOurPushTheOnlyTruth() {
        #expect(SyncRules.shouldPreferFlushedWitness(
            flushedTime: 40, flushedAtMs: 1_000, serverTime: 0, serverUpdateMs: 0))
    }

    /// the reviewer's case 3: the server ANSWERS, but without a progress entry. An
    /// answer without a date is not a statement about the position.
    @Test func answerWithoutDateDoesNotBeatTheWitness() {
        #expect(SyncRules.shouldPreferFlushedWitness(
            flushedTime: 40, flushedAtMs: 1_000, serverTime: 0, serverUpdateMs: 0))
    }

    /// The guard that matters: another device that is genuinely ahead keeps
    /// winning. Otherwise the fix would trade a null start for a rollback.
    @Test func newerForeignDeviceStillWins() {
        #expect(!SyncRules.shouldPreferFlushedWitness(
            flushedTime: 40, flushedAtMs: 1_000, serverTime: 900, serverUpdateMs: 2_000))
    }

    /// Our own echo: the server holds exactly what we pushed, dated later.
    /// Taking the witness here would be pointless, not wrong — but it must
    /// not fire, so the server stays the store of record.
    @Test func ownEchoDoesNotFire() {
        #expect(!SyncRules.shouldPreferFlushedWitness(
            flushedTime: 40, flushedAtMs: 1_000, serverTime: 40, serverUpdateMs: 1_500))
    }

    /// A witness at 0 is no witness — a fresh install must not be dragged to 0.
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

    /// Below the tolerance nothing changes — the same 5 s the sibling rule uses.
    @Test func tinyDifferenceIsNotWorthAJump() {
        #expect(!SyncRules.shouldPreferFlushedWitness(
            flushedTime: 103, flushedAtMs: 5_000, serverTime: 100, serverUpdateMs: 1_000))
    }
}

/// 5f4fdee — das Stomp-Fenster. Der gefaehrliche Pfad braucht einen Testfall:
/// frische Sitzung, Position nahe 0, Server deutlich voraus.
@Suite("Ein Start ohne Antwort darf nichts zum Server schreiben")
struct StompWindowTests {

    /// Der gemeldete Realfall: Vollplayer bei 00:00, Server bei 8:29:33.
    /// Ein Push von hier ueberschriebe acht Stunden.
    @Test func unresolvedStartMayNotPush() {
        #expect(!SyncRules.mayPushProgress(startSourceResolved: false))
    }

    /// „Der Server weiss nichts" IST eine Antwort — ein wirklich neues Buch
    /// muss seinen Fortschritt melden koennen.
    @Test func answeredStartPushesAsBefore() {
        #expect(SyncRules.mayPushProgress(startSourceResolved: true))
    }
}

struct TrackMathTests {

    private func track(index: Int, start: Double? = nil, duration: Double?) -> ABSAudioTrack {
        ABSAudioTrack(index: index, startOffset: start, duration: duration, contentUrl: "t\(index)", metadata: nil)
    }

    /// Drei Tracks à 100 s, Buchdauer 300.
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
        (time: 999.0, expected: 2)  // hinter Buchende → letzter Track
    ])
    func trackIndexForAbsoluteTime(time: Double, expected: Int) {
        #expect(TrackMath.trackIndex(for: time, tracks: tracks, bookDuration: 300) == expected)
    }

    @Test("Fehlende Dauern dürfen nicht crashen; Rest fällt auf letzten Track")
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
