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
