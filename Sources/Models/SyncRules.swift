import Foundation

/// Reine, zustandslose Entscheidungsregeln des Sync-Kerns — hierher extrahiert,
/// damit sie ohne Player/Netz/Dateisystem unit-testbar sind. Verhalten ist
/// identisch zu den früheren Inline-Versionen in PlayerViewModel/SyncQueue.
enum SyncRules {

    /// Geräte-Abgleich: Serverstand übernehmen?
    /// Mit Zeitstempel: neuerer Eintrag + spürbare Abweichung (auch rückwärts).
    /// Ohne Zeitstempel (alte Server): nur vorwärts.
    static func shouldAdoptServerState(
        serverTime: Double,
        serverUpdateMs: Double,
        lastKnownServerUpdateMs: Double,
        currentTime: Double,
        tolerance: Double = 5
    ) -> Bool {
        if serverUpdateMs > 0 {
            return serverUpdateMs > lastKnownServerUpdateMs
                && abs(serverTime - currentTime) > tolerance
        }
        return serverTime > currentTime + tolerance
    }

    /// Queue-Flush: wartendes Update verwerfen, weil der Server inzwischen
    /// weiter ist? isFinished-Updates sind Statusentscheidungen und werden
    /// nie verworfen.
    static func shouldDropQueuedUpdate(
        queuedTime: Double,
        queuedIsFinished: Bool,
        duration: Double,
        serverFraction: Double?,
        tolerance: Double = 5
    ) -> Bool {
        guard !queuedIsFinished, duration > 0, let fraction = serverFraction else { return false }
        return fraction * duration > queuedTime + tolerance
    }

    /// Crash-Sicherung: lokale Tick-Sicherung statt Serverstand verwenden?
    /// Nur wenn sie JÜNGER als der Server-Eintrag ist und spürbar abweicht.
    static func shouldRestoreLocalPosition(
        savedTime: Double,
        savedAtMs: Double,
        serverTime: Double,
        serverUpdateMs: Double,
        tolerance: Double = 5
    ) -> Bool {
        savedAtMs > serverUpdateMs && abs(savedTime - serverTime) > tolerance
    }

    /// Nicht vom Nutzer ausgelöster Rückschritt, der als verdächtig gilt?
    static func isSuspiciousDrop(
        currentTime: Double,
        lastSyncedTime: Double,
        threshold: Double
    ) -> Bool {
        currentTime < lastSyncedTime - threshold
    }
}

/// Multi-File-Zeitrechnung: absolute Buchzeit ↔ Track-Index. Rein und
/// unit-testbar; PlayerViewModel delegiert hierher.
enum TrackMath {

    /// Kumulative Startzeit eines Tracks: startOffset vom Server, sonst Summe
    /// der Einzeldauern. Außerhalb des Bereichs: Buchdauer.
    static func trackStart(index: Int, tracks: [ABSAudioTrack], bookDuration: Double) -> Double {
        guard index >= 0, index < tracks.count else { return bookDuration }
        if let offset = tracks[index].startOffset { return offset }
        return tracks[..<index].reduce(0) { $0 + ($1.duration ?? 0) }
    }

    /// Track, in den eine absolute Buchzeit fällt (letzter Track fängt Rest).
    static func trackIndex(for absoluteTime: Double, tracks: [ABSAudioTrack], bookDuration: Double) -> Int {
        for index in tracks.indices {
            let start = trackStart(index: index, tracks: tracks, bookDuration: bookDuration)
            let end = start + (tracks[index].duration ?? 0)
            if absoluteTime < end || index == tracks.count - 1 {
                return index
            }
        }
        return 0
    }
}
