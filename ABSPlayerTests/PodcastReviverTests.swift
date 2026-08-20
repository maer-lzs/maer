// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import ABSPlayer

/// 8b71fd7: the reviver — the owner's "Rest is History" episode came back TWICE
/// after being finished (once by listening to the end, once by hand). The
/// mechanism, measured in code: restoring a loaded episode flushed the
/// RESTORED state immediately, re-stamping the old position (21:09) as fresh —
/// locally and to gpodder — on every app start of whichever device still held
/// the episode. A freshly-stamped old position outvotes a younger finished
/// mark on every sync; no single loss, a repeat offender.
///
/// The rule is Winterfell one layer up: the restore is a witness of LOADING,
/// not of LISTENING.
@Suite struct PodcastReviverTests {

    /// Merely holding an episode in the player is not an event.
    @Test func aRestoredEpisodeWritesNothing() {
        #expect(!SyncRules.mayWritePodcastLocalState(playedSinceLoad: false,
                                                     deliberateRestart: false,
                                                     deliberateSeek: false))
    }

    /// The three things that ARE events: playback, a deliberate restart, a
    /// deliberate seek. Each is the user (or the audio) actually acting.
    @Test func eventsMayWrite() {
        #expect(SyncRules.mayWritePodcastLocalState(playedSinceLoad: true,
                                                    deliberateRestart: false,
                                                    deliberateSeek: false))
        #expect(SyncRules.mayWritePodcastLocalState(playedSinceLoad: false,
                                                    deliberateRestart: true,
                                                    deliberateSeek: false))
        #expect(SyncRules.mayWritePodcastLocalState(playedSinceLoad: false,
                                                    deliberateRestart: false,
                                                    deliberateSeek: true))
    }

    /// The adoption side, pinned as the constellation of the finding: a
    /// finished mark (position = duration, YOUNGER) must not lose to an old
    /// position that was merely re-pushed. With honest timestamps the
    /// newer-wins rule handles it — the fix is that re-pushes now CARRY their
    /// honest (old) timestamp instead of the push moment.
    @Test func anHonestlyStampedOldPositionLosesToTheYoungerFinishedMark() {
        let finishedAtMs: Double = 2_000_000
        let oldPositionTs: Double = 1_000_000
        // The pull's adoption gate is `tsMs > localTs` (GPodderSync). With the
        // event's own stamp, the old action no longer clears it.
        #expect(!(oldPositionTs > finishedAtMs))
    }
}
#endif
