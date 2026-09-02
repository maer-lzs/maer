// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation

/// One listening state as another app hands it over: which episode, how
/// far, whether finished, and WHEN the source last recorded it.
///
/// The seam every importer feeds and the one adopter reads. It is
/// deliberately wider than any single source: Overcast has no episode
/// GUID but an episode link, AntennaPod has the GUID, Apple has neither
/// link nor GUID. The adopter's ladder walks what is there.
nonisolated struct ForeignListeningState: Sendable, Equatable {
    /// The show. nil where the source stores the episode without its
    /// feed on the same row; the ladder then searches every show.
    var feedURL: String?
    var episodeGUID: String?
    var enclosureURL: String?
    var episodeLink: String?
    var episodeTitle: String?
    /// Seconds into the episode.
    var position: Double
    /// The episode length as the source knows it, seconds. nil where the
    /// source stores none; a feed without a duration then keeps none.
    var duration: Double? = nil
    var finished: Bool
    /// The SOURCE's moment for this state, milliseconds since 1970. nil
    /// when the source records none; then the state may only fill a gap.
    var stampedAt: Double?
}

/// Where an import comes from. The surface names per source what the
/// format can carry; what a given file actually carries is counted.
nonisolated enum ForeignSource: String, Sendable, CaseIterable {
    /// A plain OPML or Overcast's extended one; which of the two it is
    /// shows in the library, not in the source.
    case opml
    case applePodcasts
    /// AntennaPod's database export, a plain SQLite file.
    case antennaPod
}

/// Everything one file or database of a foreign app hands over.
nonisolated struct ForeignLibrary: Sendable, Equatable {
    /// Every feed to subscribe, in source order.
    var feedURLs: [String]
    /// Listening states of the episodes the source carries.
    var states: [ForeignListeningState]
    /// Subscriptions without a public feed (paid or exclusive), which no
    /// import can reach. Counted for the surface instead of vanishing.
    var unimportablePaidCount = 0
}

/// The conflict rule between a foreign state and what this device knows,
/// the same for every source.
///
/// Three stages, decided:
/// (a) both sides carry a real moment: the NEWER wins, whatever its
///     position;
/// (b) the source carries no moment: it may only FILL where nothing is
///     known, never overwrite;
/// (c) "finished" is never taken back, not even by a newer "unfinished":
///     not knowing beats no knowing.
///
/// A local entry is the stored `[position, momentMs]` pair of the
/// listening store; an old one-value entry counts as a moment of zero.
nonisolated enum ForeignStateMerge {
    /// Of two rows the SAME source holds for one episode, the one that
    /// speaks for it: the newer moment; without moments, finished over
    /// unfinished, then the further position. Applied before the rule,
    /// because the rule protects local knowledge and would let whichever
    /// finished row arrives first shield a newer unfinished one.
    static func preferred(_ a: ForeignListeningState, _ b: ForeignListeningState) -> ForeignListeningState {
        if let sa = a.stampedAt, let sb = b.stampedAt, sa != sb { return sa > sb ? a : b }
        if a.finished != b.finished { return a.finished ? a : b }
        return a.position >= b.position ? a : b
    }

    /// The entry to store, or nil when the local knowledge stays.
    static func adopt(local: [Double]?, foreign: ForeignListeningState,
                      duration: Double) -> [Double]? {
        let time: Double
        if foreign.finished {
            time = duration > 0 ? max(duration, foreign.position) : ProgressMark.playedSentinel
        } else {
            time = foreign.position
        }
        guard time > 1 else { return nil }
        let localPosition = local?.first ?? 0
        let localMoment = local.flatMap { $0.count > 1 ? $0[1] : 0 } ?? 0
        let localKnown = localPosition > 0
        let localPlayed = local.map { ProgressMark.isPlayed(stored: $0, currentDuration: duration) } ?? false
        // (c) finished stays finished.
        if localPlayed { return nil }
        // (b) no moment at the source: fill only, stamped with zero so any
        // real later moment wins against it.
        guard let stamped = foreign.stampedAt else {
            guard !localKnown else { return nil }
            return ProgressMark.advancing(local, position: time, duration: duration, nowMs: 0)
        }
        // (a) the newer side wins. Equal moments are an honest tie and
        // the local side keeps it. Through `advancing`, so a reference
        // point the local entry carries survives the adoption.
        guard stamped > localMoment || !localKnown else { return nil }
        return ProgressMark.advancing(local, position: time, duration: duration, nowMs: stamped)
    }
}
