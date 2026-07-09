import XCTest
@testable import ABSPlayer

/// Tests für die reinen Sync-Entscheidungsregeln (SyncRules) und die
/// Multi-File-Zeitrechnung (TrackMath) — der gehärtete Kern der App.
final class SyncRulesTests: XCTestCase {

    // MARK: - Geräte-Abgleich (shouldAdoptServerState)

    func testAdoptsNewerServerEntryForward() {
        XCTAssertTrue(SyncRules.shouldAdoptServerState(
            serverTime: 500, serverUpdateMs: 2000, lastKnownServerUpdateMs: 1000, currentTime: 100
        ))
    }

    func testAdoptsNewerServerEntryBackward() {
        // Bewusstes Zurückspulen auf anderem Gerät: neuerer Eintrag gewinnt
        // auch rückwärts.
        XCTAssertTrue(SyncRules.shouldAdoptServerState(
            serverTime: 100, serverUpdateMs: 2000, lastKnownServerUpdateMs: 1000, currentTime: 500
        ))
    }

    func testIgnoresOlderServerEntry() {
        XCTAssertFalse(SyncRules.shouldAdoptServerState(
            serverTime: 500, serverUpdateMs: 1000, lastKnownServerUpdateMs: 2000, currentTime: 100
        ))
    }

    func testIgnoresOwnWriteEcho() {
        // Nach eigenem Write: Eintrag neuer, Position aber (fast) identisch.
        XCTAssertFalse(SyncRules.shouldAdoptServerState(
            serverTime: 101, serverUpdateMs: 2000, lastKnownServerUpdateMs: 1000, currentTime: 100
        ))
    }

    func testLegacyServerWithoutTimestampOnlyForward() {
        XCTAssertTrue(SyncRules.shouldAdoptServerState(
            serverTime: 500, serverUpdateMs: 0, lastKnownServerUpdateMs: 0, currentTime: 100
        ))
        XCTAssertFalse(SyncRules.shouldAdoptServerState(
            serverTime: 100, serverUpdateMs: 0, lastKnownServerUpdateMs: 0, currentTime: 500
        ))
    }

    // MARK: - Queue-Flush (shouldDropQueuedUpdate)

    func testDropsStaleQueuedUpdateWhenServerIsAhead() {
        XCTAssertTrue(SyncRules.shouldDropQueuedUpdate(
            queuedTime: 100, queuedIsFinished: false, duration: 1000, serverFraction: 0.5
        ))
    }

    func testKeepsQueuedUpdateWhenServerIsBehind() {
        XCTAssertFalse(SyncRules.shouldDropQueuedUpdate(
            queuedTime: 600, queuedIsFinished: false, duration: 1000, serverFraction: 0.5
        ))
    }

    func testNeverDropsFinishedUpdates() {
        // Statusentscheidung — bleibt auch, wenn der Server weiter ist.
        XCTAssertFalse(SyncRules.shouldDropQueuedUpdate(
            queuedTime: 100, queuedIsFinished: true, duration: 1000, serverFraction: 0.9
        ))
    }

    func testKeepsQueuedUpdateWithoutServerEntryOrDuration() {
        XCTAssertFalse(SyncRules.shouldDropQueuedUpdate(
            queuedTime: 100, queuedIsFinished: false, duration: 1000, serverFraction: nil
        ))
        XCTAssertFalse(SyncRules.shouldDropQueuedUpdate(
            queuedTime: 100, queuedIsFinished: false, duration: 0, serverFraction: 0.9
        ))
    }

    // MARK: - Crash-Sicherung (shouldRestoreLocalPosition)

    func testRestoresNewerLocalPosition() {
        XCTAssertTrue(SyncRules.shouldRestoreLocalPosition(
            savedTime: 200, savedAtMs: 2000, serverTime: 100, serverUpdateMs: 1000
        ))
    }

    func testIgnoresOlderLocalPosition() {
        XCTAssertFalse(SyncRules.shouldRestoreLocalPosition(
            savedTime: 200, savedAtMs: 1000, serverTime: 100, serverUpdateMs: 2000
        ))
    }

    func testIgnoresLocalPositionMatchingServer() {
        XCTAssertFalse(SyncRules.shouldRestoreLocalPosition(
            savedTime: 102, savedAtMs: 2000, serverTime: 100, serverUpdateMs: 1000
        ))
    }

    // MARK: - Verdächtiger Rückschritt (isSuspiciousDrop)

    func testDetectsSuspiciousDrop() {
        XCTAssertTrue(SyncRules.isSuspiciousDrop(currentTime: 0, lastSyncedTime: 500, threshold: 120))
        XCTAssertFalse(SyncRules.isSuspiciousDrop(currentTime: 450, lastSyncedTime: 500, threshold: 120))
        XCTAssertFalse(SyncRules.isSuspiciousDrop(currentTime: 600, lastSyncedTime: 500, threshold: 120))
    }
}

final class TrackMathTests: XCTestCase {

    private func track(index: Int, start: Double? = nil, duration: Double?) -> ABSAudioTrack {
        ABSAudioTrack(index: index, startOffset: start, duration: duration, contentUrl: "t\(index)")
    }

    // Drei Tracks à 100s, Buchdauer 300.
    private var tracks: [ABSAudioTrack] {
        [track(index: 0, duration: 100), track(index: 1, duration: 100), track(index: 2, duration: 100)]
    }

    func testTrackStartSumsDurations() {
        XCTAssertEqual(TrackMath.trackStart(index: 0, tracks: tracks, bookDuration: 300), 0)
        XCTAssertEqual(TrackMath.trackStart(index: 2, tracks: tracks, bookDuration: 300), 200)
    }

    func testTrackStartPrefersServerOffset() {
        let t = [track(index: 0, duration: 100), track(index: 1, start: 90, duration: 100)]
        XCTAssertEqual(TrackMath.trackStart(index: 1, tracks: t, bookDuration: 190), 90)
    }

    func testTrackStartOutOfRangeReturnsBookDuration() {
        XCTAssertEqual(TrackMath.trackStart(index: 5, tracks: tracks, bookDuration: 300), 300)
        XCTAssertEqual(TrackMath.trackStart(index: -1, tracks: tracks, bookDuration: 300), 300)
    }

    func testTrackIndexWithinTracks() {
        XCTAssertEqual(TrackMath.trackIndex(for: 0, tracks: tracks, bookDuration: 300), 0)
        XCTAssertEqual(TrackMath.trackIndex(for: 99.9, tracks: tracks, bookDuration: 300), 0)
        XCTAssertEqual(TrackMath.trackIndex(for: 100, tracks: tracks, bookDuration: 300), 1)
        XCTAssertEqual(TrackMath.trackIndex(for: 250, tracks: tracks, bookDuration: 300), 2)
    }

    func testTrackIndexBeyondEndClampsToLastTrack() {
        XCTAssertEqual(TrackMath.trackIndex(for: 999, tracks: tracks, bookDuration: 300), 2)
    }

    func testTrackIndexWithMissingDurations() {
        // Fehlende Dauern (0) dürfen nicht crashen; Rest fällt auf letzten Track.
        let t = [track(index: 0, duration: nil), track(index: 1, duration: 100)]
        XCTAssertEqual(TrackMath.trackIndex(for: 50, tracks: t, bookDuration: 100), 1)
    }
}
