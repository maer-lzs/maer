// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
@testable import Maer

/// Tests für die reinen Sync-Entscheidungsregeln (SyncRules) und die
/// Multi-File-Zeitrechnung (TrackMath). Der gehärtete Kern der App.
struct SyncRulesTests {

    // MARK: - Eigenes Echo nach einem Funkloch (isOwnServerEcho, E133)

    @Test("Funkloch: der Server haelt den eigenen Schrieb von vor 35 s, die Warteschlange ist weiter, lokal bleibt")
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

    @Test("ein fremdes Geraet voraus wird weiter uebernommen, auch mit eigener Warteschlange")
    func aForeignDeviceAheadIsStillAdopted() {
        #expect(!SyncRules.isOwnServerEcho(serverTime: 1200, lastSyncedTime: 1000,
                                           flushedTime: 965, queuedTime: 1000))
        #expect(SyncRules.shouldAdoptServerState(
            serverTime: 1200, serverUpdateMs: 2000, lastKnownServerUpdateMs: 1000, currentTime: 1000))
    }

    @Test("ein bewusstes Zurueckspulen des anderen Geraets ohne eigene Warteschlange wird uebernommen")
    func aForeignRewindWithoutAQueueIsAdopted() {
        #expect(!SyncRules.isOwnServerEcho(serverTime: 500, lastSyncedTime: 1000,
                                           flushedTime: 965, queuedTime: nil))
    }

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

/// The flushed witness. Every case here is one the MEASUREMENT
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

    /// Third case: the server ANSWERS, but without a progress entry. An
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

/// Das Stomp-Fenster. Der gefaehrliche Pfad braucht einen Testfall:
/// frische Sitzung, Position nahe 0, Server deutlich voraus.
@Suite("Ein Start ohne Antwort darf nichts zum Server schreiben")
struct StompWindowTests {

    /// Der gemeldete Realfall: Vollplayer bei 00:00, Server bei 8:29:33.
    /// Ein Push von hier ueberschriebe acht Stunden.
    @Test func unresolvedStartMayNotPush() {
        #expect(!SyncRules.mayPushProgress(startSourceResolved: false))
    }

    /// Ein Server, der nichts weiss, IST eine Antwort. Ein wirklich neues Buch
    /// muss seinen Fortschritt melden koennen.
    @Test func answeredStartPushesAsBefore() {
        #expect(SyncRules.mayPushProgress(startSourceResolved: true))
    }
}

/// Die dritte Erscheinung der eingefrorenen Null.
@Suite("Weiterhoeren fragt die gewonnene Quelle")
struct ContinueStartedTests {

    /// the reviewer's Testfall: heruntergeladen, Detail-Progress leer, Server voraus.
    /// Die Karte MUSS stehen. Der Zeuge ist der Beweis des Angefangenhabens.
    @Test func frozenZeroDoesNotDeleteTheCard() {
        #expect(ContinueSources.isStarted(serverSaysStarted: false,
                                          flushed: [8_000, 1_000]))
    }

    @Test func serverSaysStartedIsEnough() {
        #expect(ContinueSources.isStarted(serverSaysStarted: true, flushed: nil))
    }

    /// Ein Antippen ist kein begonnenes Buch. Dieselbe 30-s-Kante wie in
    /// `started(in:)`, nicht eine zweite erfunden.
    @Test func aTapIsNotAStartedBook() {
        #expect(!ContinueSources.isStarted(serverSaysStarted: false, flushed: [12, 1_000]))
        #expect(!ContinueSources.isStarted(serverSaysStarted: false, flushed: nil))
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
