// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Pure, stateless decision rules of the sync core — extracted here so they are
/// unit-testable without player/network/file system. Behaviour is identical to
/// the former inline versions in PlayerViewModel/SyncQueue. `nonisolated`: pure
/// Foundation logic, callable from background/test contexts under the project's
/// default MainActor isolation.
nonisolated enum SyncRules {

    /// Device reconcile: adopt the server state?
    /// With timestamp: newer entry + noticeable difference (also backwards).
    /// Without timestamp (old servers): forward only.
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

    /// Device reconcile: is the server entry (within tolerance) exactly the
    /// state WE last wrote? A reconcile must not mistake our own echo for a
    /// foreign device — server clocks can run ahead of the device clock, so a
    /// pure timestamp comparison is not enough after an offline stretch.
    static func isOwnServerEcho(
        serverTime: Double,
        lastSyncedTime: Double,
        tolerance: Double = 5
    ) -> Bool {
        abs(serverTime - lastSyncedTime) <= tolerance
    }

    /// Queue flush: drop a pending update because the server is now further
    /// ahead? isFinished updates are status decisions and are never dropped.
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

    /// Crash safety: use the local tick backup instead of the server state?
    /// Only if it is NEWER than the server entry and differs noticeably.
    static func shouldRestoreLocalPosition(
        savedTime: Double,
        savedAtMs: Double,
        serverTime: Double,
        serverUpdateMs: Double,
        tolerance: Double = 5
    ) -> Bool {
        savedAtMs > serverUpdateMs && abs(savedTime - serverTime) > tolerance
    }

    /// A non-user-initiated backward jump considered suspicious?
    static func isSuspiciousDrop(
        currentTime: Double,
        lastSyncedTime: Double,
        threshold: Double
    ) -> Bool {
        currentTime < lastSyncedTime - threshold
    }
}

/// Multi-file time math: absolute book time ↔ track index. Pure and
/// unit-testable; PlayerViewModel delegates here.
/// `nonisolated`: pure track-offset math, callable from background/nonisolated
/// contexts (e.g. ChapterModel's track fallback).
nonisolated enum TrackMath {

    /// Cumulative start time of a track: startOffset from the server, else the
    /// sum of the individual durations. Out of range: book duration.
    static func trackStart(index: Int, tracks: [ABSAudioTrack], bookDuration: Double) -> Double {
        guard index >= 0, index < tracks.count else { return bookDuration }
        if let offset = tracks[index].startOffset { return offset }
        return tracks[..<index].reduce(0) { $0 + ($1.duration ?? 0) }
    }

    /// Track that an absolute book time falls into (last track catches the rest).
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
