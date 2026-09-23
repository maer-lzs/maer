// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation

/// What the player knows when a sync starts, as values. Every fact here is
/// fixed for the length of one sync: the provider is a constant, and the pot
/// and the podcast namespace are rules over the item id. The one fact that
/// can change during the write, whether anything happened since the load,
/// is not part of it (see `SyncPlan.local(eventSinceLoad:)`).
nonisolated struct SyncState: Equatable, Sendable {
    var startSourceResolved: Bool
    var currentTime: Double
    var lastSyncedTime: Double
    var suspiciousDropThreshold: Double
    var suppressConflict: Bool
    var conflictPending: Bool
    /// The source keeps a server progress (books); scrobblers and radio do not.
    var progressSync: Bool
    var podcastEpisode: Bool
    var potCarries: Bool
}

/// Everything a sync does, decided before it does it. The player only
/// carries it out; a table of occasions and states is its behaviour witness.
nonisolated struct SyncPlan: Equatable, Sendable {
    enum Gate: Equatable, Sendable {
        case write
        /// No source answered the start; not even a deliberate sync pushes.
        case unresolvedStart
        /// A tick, less than five seconds from the last written position.
        case belowThreshold
        /// A backward jump the user did not ask for is never written
        /// silently. `raise` is false while a conflict is already shown.
        case conflict(raise: Bool)
    }

    enum Local: Equatable, Sendable {
        /// Books on a progress source: the crash backup goes, the flushed
        /// witness stays.
        case flushBackup
        /// Everything else: the local position is written, the episode
        /// state follows.
        case recordEpisode
        case nothing
    }

    var gate: Gate
    /// One log line per deliberate write, never per tick.
    var logWrite: Bool
    /// After a landed write: the history stamp and the server's moment.
    var noteServerWrite: Bool
    /// After a landed write: the library model learns the position.
    var noteLibrary: Bool
    var flushesBackup: Bool
    /// When the episode state is recorded, gpodder hears it too.
    var gpodder: Bool
    /// When the episode state is recorded, the pot is sent at once rather
    /// than within its cadence.
    var potDeliberate: Bool

    /// The local write after a landed write. `eventSinceLoad` is read by the
    /// caller at THAT moment, as it always was: a play or a seek during the
    /// write counts. Restoring is loading, not listening.
    func local(eventSinceLoad: Bool) -> Local {
        if flushesBackup { return .flushBackup }
        return SyncRules.mayWritePodcastLocalState(playedSinceLoad: eventSinceLoad,
                                                   deliberateRestart: false,
                                                   deliberateSeek: false)
            ? .recordEpisode : .nothing
    }
}

nonisolated extension SyncRules {
    /// The plan of one sync. The occasion decides only what `force` decided:
    /// a deliberate occasion passes the five-second threshold and sends the
    /// pot at once. Any further distinction by occasion would change how
    /// positions are written.
    static func plan(origin: SyncOrigin, state: SyncState) -> SyncPlan {
        let deliberate = origin.isDeliberate
        let gate: SyncPlan.Gate
        if !mayPushProgress(startSourceResolved: state.startSourceResolved) {
            gate = .unresolvedStart
        } else if !deliberate && abs(state.currentTime - state.lastSyncedTime) < 5 {
            gate = .belowThreshold
        } else if !state.suppressConflict,
                  isSuspiciousDrop(currentTime: state.currentTime,
                                   lastSyncedTime: state.lastSyncedTime,
                                   threshold: state.suspiciousDropThreshold) {
            gate = .conflict(raise: !state.conflictPending)
        } else {
            gate = .write
        }
        return SyncPlan(gate: gate,
                        logWrite: deliberate,
                        noteServerWrite: state.progressSync,
                        noteLibrary: !state.potCarries,
                        flushesBackup: state.progressSync && !state.podcastEpisode,
                        gpodder: state.podcastEpisode,
                        potDeliberate: deliberate)
    }
}
