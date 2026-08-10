// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation

/// How "played" is stored and read back.
///
/// **Measured, not assumed:** shows hosted on Megaphone get ads inserted
/// RANDOMLY per request — the platform's own documentation calls it "random
/// ad insertion… it may show up or not in any given request". The reported
/// duration is therefore **not a stable property** for that class of show.
///
/// "Played" used to mean `position >= today's duration - 1`. When the duration
/// grew by three minutes between two fetches, the mark fell below the
/// threshold and six finished episodes showed "3 min left" again — anew after
/// every refresh. A server-side counter-check (41 episodes, 38 exactly on
/// `total`, none near the end) ruled out the sync path: the defect was in the
/// local back-derivation.
///
/// So the entry carries the duration that was valid when it was written:
/// `[position, timestamp, duration at the time]`. "Played" then means **"the
/// position matches the duration that applied back then"** — regardless of how
/// much advertising is in today's copy. Older entries (`count == 2`) behave
/// unchanged, and **outward** the real end position still goes out: gpodder and
/// Audiobookshelf expect `position = total`, and rightly so.
nonisolated enum ProgressMark {
    /// The position that means "played" for episodes that report no duration.
    /// 30 days — beyond any real episode and small enough for the `Int`
    /// conversion in the gpodder push (infinity would trap there).
    static let playedSentinel: Double = 2_592_000

    /// The entry to store. The duration only travels along when it is known —
    /// an invented value would be worse than none.
    ///
    /// **Do not call this when an entry already exists** — that is what
    /// `advancing` is for. This form builds a NEW one and drops whatever it
    /// does not know.
    static func entry(position: Double, duration: Double, nowMs: Double) -> [Double] {
        duration > 0 ? [position, nowMs, duration] : [position, nowMs]
    }

    /// **Carry forward instead of rebuilding.**
    ///
    /// An incoming entry without a known duration must not delete an EXISTING
    /// reference point — it does not know better, it does not know at all.
    /// That is exactly what happened: the gpodder pull called `entry` with
    /// `total ?? 0` and, on a younger timestamp, wrote a two-value mark over a
    /// good three-value one. The push stamps `Date()` at push time rather than
    /// the entry's own timestamp, so even a device's own echo came back
    /// younger and won — no playback, no gesture, in sync with the sync.
    ///
    /// Same class as the field classes in the show merge: **knowledge only one
    /// side has must not die because the other side wins.** It lives here and
    /// not at the call sites, so no future caller can lose it either.
    static func advancing(_ existing: [Double]?,
                          position: Double,
                          duration: Double,
                          nowMs: Double) -> [Double] {
        let known = duration > 0 ? duration : (existing.flatMap { markedDuration($0) } ?? 0)
        return entry(position: position, duration: known, nowMs: nowMs)
    }

    /// **Supplementing:** add ONLY the missing reference point to an entry
    /// that already exists — position and timestamp stay untouched. This is
    /// not a merge and not an adoption, which is why it asks no question about
    /// timestamps: for the affected episodes both sides stem from the SAME
    /// event, so the server is never newer.
    ///
    /// `nil` means "nothing to do": the entry already has one, or the other
    /// side knows no duration. An entry is NEVER created from nothing — a
    /// repair that resurrects deleted state is the class the subscription
    /// merge guards against with its mass-deletion check.
    static func supplementing(_ existing: [Double], duration: Double) -> [Double]? {
        guard duration > 0, existing.count >= 2, markedDuration(existing) == nil else { return nil }
        return [existing[0], existing[1], duration]
    }

    /// When the entry was last written (milliseconds since 1970).
    ///
    /// Read it through here, never as `.last`: since the mark carries a third
    /// value, `.last` is the DURATION (~3600) instead of a timestamp (~1.7e12),
    /// and every comparison built on it silently picks the wrong side.
    static func timestamp(_ stored: [Double]?) -> Double? {
        guard let stored, stored.count >= 2 else { return nil }
        return stored[1]
    }

    /// The duration that applied when the entry was written — if it carries one.
    static func markedDuration(_ stored: [Double]) -> Double? {
        stored.count >= 3 && stored[2] > 0 ? stored[2] : nil
    }

    /// Three states of an episode for the UI — unplayed, in progress (with a
    /// remaining time) or fully played. Foundation-only on purpose: the
    /// decision below belongs next to the mark it reads, not to a view.
    enum PlayState: Equatable, Sendable {
        case unplayed
        case inProgress(fraction: Double, remaining: Double)
        case played
    }

    /// THE answer to "how far is this episode". Both the reactive store and
    /// the off-main sections compute call this — they used to carry two
    /// versions of it with the same signature, and only one of them knew
    /// about the marked duration. That is why a healed entry stayed invisible
    /// in exactly the two surfaces that show the symptom.
    static func state(stored: [Double]?, currentDuration: Double) -> PlayState {
        guard let stored, stored.count >= 2 else { return .unplayed }
        if isPlayed(stored: stored, currentDuration: currentDuration) { return .played }
        guard currentDuration > 0 else { return .unplayed }
        let time = stored[0]
        guard time > 1 else { return .unplayed }
        return .inProgress(fraction: min(max(time / currentDuration, 0), 1),
                           remaining: currentDuration - time)
    }

    /// Does the entry count as played?
    ///
    /// The order is deliberate: sentinel first (it needs no duration), then the
    /// STORED duration, and only last today's — that last step is the old path
    /// and applies only to entries without a third value.
    static func isPlayed(stored: [Double], currentDuration: Double) -> Bool {
        guard let position = stored.first else { return false }
        if position >= playedSentinel { return true }
        if let marked = markedDuration(stored) { return position >= marked - 1 }
        guard currentDuration > 0 else { return false }
        return position >= currentDuration - 1
    }
}

/// The name the UI has always used. One type, one decision — the alias keeps
/// the call sites untouched while the truth lives in `ProgressMark`.
typealias EpisodePlayState = ProgressMark.PlayState
