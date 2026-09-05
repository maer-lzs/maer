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
    /// The show's name as the SOURCE calls it. A state no episode claims
    /// is named by its show in the preview, or nobody can place it.
    var showTitle: String? = nil
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
    /// The source had put the episode away (Pocket Casts archive,
    /// Overcast's `userDeleted`). Counts as finished on import and is
    /// kept, so an export carries it back out as archived.
    var archived: Bool = false
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
    /// Pocket Casts, read from the person's own account in one pass.
    case pocketCasts

    /// Whether the source is a file the person picks; Pocket Casts is
    /// reached through a sign-in instead.
    var isFile: Bool { self != .pocketCasts }

    /// Whether the format can say WHEN an episode was heard. Pocket
    /// Casts cannot; its states only ever fill gaps.
    var carriesMoments: Bool { self != .pocketCasts }
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

    /// Why an entry was adopted. Counted per import, so a run that adopts
    /// where it should not can be read by reason instead of guessed at.
    enum Reason: String, Sendable, CaseIterable {
        /// Nothing was known locally.
        case filled
        /// Both sides carried a moment and the foreign one was newer.
        case newer
        /// The local entry had a position but no moment, so any foreign
        /// moment counted as newer.
        case oneValue
    }

    /// The entry to store, or nil when the local knowledge stays.
    static func adopt(local: [Double]?, foreign: ForeignListeningState,
                      duration: Double) -> [Double]? {
        adoption(local: local, foreign: foreign, duration: duration)?.entry
    }

    /// Why a foreign state stays out. The surface tells "this device knew
    /// better" from "there was nothing to take over": on a fresh device the
    /// first must read zero, or the person reads an error that is none.
    enum Keep: String, Sendable, CaseIterable {
        /// Under a second played and not finished: no state at all.
        case nothingToAdopt
        /// The episode is finished here.
        case localPlayed
        /// The source carries no moment and this device already knows the
        /// episode (from iCloud or an earlier import).
        case localKnown
        /// Both carry a moment and the local one is newer or equal.
        case localNewer
    }

    enum Verdict: Sendable, Equatable {
        case adopt(entry: [Double], reason: Reason)
        case keep(Keep)
    }

    /// The entry with its reason, or nil when the local knowledge stays.
    static func adoption(local: [Double]?, foreign: ForeignListeningState,
                         duration: Double) -> (entry: [Double], reason: Reason)? {
        guard case .adopt(let entry, let reason) = verdict(local: local, foreign: foreign, duration: duration) else {
            return nil
        }
        return (entry, reason)
    }

    /// The ONE rule, with the reason on both sides.
    /// Moments compare on whole milliseconds: the store stamps with
    /// fractions, the exchange formats carry none, and a fraction that
    /// rounds up made a device's own export look newer than its store.
    static func verdict(local: [Double]?, foreign: ForeignListeningState,
                        duration: Double) -> Verdict {
        let time: Double
        if foreign.finished {
            time = duration > 0 ? max(duration, foreign.position) : ProgressMark.playedSentinel
        } else {
            time = foreign.position
        }
        guard time > 1 else { return .keep(.nothingToAdopt) }
        let localPosition = local?.first ?? 0
        let localMoment = (local.flatMap { $0.count > 1 ? $0[1] : 0 } ?? 0).rounded()
        // An entry with a moment is knowledge even at position zero: the
        // tombstone a person writes by marking an episode unplayed. It
        // is never filled over, and only a newer moment beats it.
        let localKnown = localPosition > 0 || localMoment > 0
        let localPlayed = local.map { ProgressMark.isPlayed(stored: $0, currentDuration: duration) } ?? false
        // (c) finished stays finished.
        if localPlayed { return .keep(.localPlayed) }
        // (b) no moment at the source: fill only, stamped with zero so any
        // real later moment wins against it.
        guard let foreignMoment = foreign.stampedAt else {
            guard !localKnown else { return .keep(.localKnown) }
            return .adopt(entry: ProgressMark.advancing(local, position: time, duration: duration, nowMs: 0),
                          reason: .filled)
        }
        let stamped = foreignMoment.rounded()
        // (a) the newer side wins. Equal moments are an honest tie and
        // the local side keeps it. Through `advancing`, so a reference
        // point the local entry carries survives the adoption.
        guard stamped > localMoment || !localKnown else { return .keep(.localNewer) }
        let reason: Reason = !localKnown ? .filled : (localMoment == 0 ? .oneValue : .newer)
        return .adopt(entry: ProgressMark.advancing(local, position: time, duration: duration, nowMs: stamped),
                      reason: reason)
    }
}
