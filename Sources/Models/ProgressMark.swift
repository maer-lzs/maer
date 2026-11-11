// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation

/// How "played" is stored and read back.
///
/// **Measured, not assumed:** shows hosted on Megaphone get ads inserted
/// RANDOMLY per request. The platform's own documentation calls it "random
/// ad insertion… it may show up or not in any given request". The reported
/// duration is therefore **not a stable property** for that class of show.
///
/// "Played" used to mean `position >= today's duration - 1`. When the duration
/// grew by three minutes between two fetches, the mark fell below the
/// threshold and six finished episodes showed "3 min left" again. Anew after
/// every refresh. A server-side counter-check (41 episodes, 38 exactly on
/// `total`, none near the end) ruled out the sync path: the defect was in the
/// local back-derivation.
///
/// So the entry carries the duration that was valid when it was written:
/// `[position, timestamp, duration at the time]`. "Played" then means **"the
/// position matches the duration that applied back then"**. Regardless of how
/// much advertising is in today's copy. Older entries (`count == 2`) behave
/// unchanged, and **outward** the real end position still goes out: gpodder and
/// Audiobookshelf expect `position = total`, and rightly so.
nonisolated enum ProgressMark {
    /// The position that means "played" for episodes that report no duration.
    /// 30 days. Beyond any real episode and small enough for the `Int`
    /// conversion in the gpodder push (infinity would trap there).
    static let playedSentinel: Double = 2_592_000

    /// The entry to store. The duration only travels along when it is known.
    /// An invented value would be worse than none.
    ///
    /// **Do not call this when an entry already exists**. That is what
    /// `advancing` is for. This form builds a NEW one and drops whatever it
    /// does not know.
    static func entry(position: Double, duration: Double, nowMs: Double,
                      form: StartedForm? = nil) -> [Double] {
        // Slot 3 needs slot 2 occupied, so an entry that knows a form but no
        // duration carries a 0 there. Which `markedDuration` already reads as
        // "none", the same way a two-value entry does.
        if let form { return [position, nowMs, max(duration, 0), form.rawValue] }
        return duration > 0 ? [position, nowMs, duration] : [position, nowMs]
    }

    /// What an item was STARTED as, when the source could say. Slot 3 of the
    /// entry, and deliberately a property of the PLAY EVENT rather than of the
    /// catalog: it describes the moment, so it cannot go stale the way a cached
    /// catalog fact would.
    ///
    /// The reason it lives in the entry at all is that the entry already
    /// travels between devices. A parallel table would need its own channel
    /// and would be a second version of the same fact.
    enum StartedForm: Double, Equatable, Sendable {
        /// A track of an album. Music. No position to return to in the
        /// product sense, so it belongs in "Listen Again", not in Continue.
        case album = 1
        /// One work in parts. Holds a position and belongs in Continue.
        case work = 2
    }

    /// The form an entry was written with. Nil when it predates this or the
    /// source could not say. **Never guessed**: an entry without a form stays
    /// out of the rows that need one.
    static func markedForm(_ stored: [Double]) -> StartedForm? {
        guard stored.count >= 4 else { return nil }
        return StartedForm(rawValue: stored[3])
    }

    /// **Carry forward instead of rebuilding.**
    ///
    /// An incoming entry without a known duration must not delete an EXISTING
    /// reference point. It does not know better, it does not know at all.
    /// That is exactly what happened: the gpodder pull called `entry` with
    /// `total ?? 0` and, on a younger timestamp, wrote a two-value mark over a
    /// good three-value one. The push stamps `Date()` at push time rather than
    /// the entry's own timestamp, so even a device's own echo came back
    /// younger and won. No playback, no gesture, in sync with the sync.
    ///
    /// Same class as the field classes in the show merge: **knowledge only one
    /// side has must not die because the other side wins.** It lives here and
    /// not at the call sites, so no future caller can lose it either.
    static func advancing(_ existing: [Double]?,
                          position: Double,
                          duration: Double,
                          nowMs: Double,
                          form: StartedForm? = nil) -> [Double] {
        let known = duration > 0 ? duration : (existing.flatMap { markedDuration($0) } ?? 0)
        // The form is carried exactly like the duration, and for the same
        // reason: this runs on every position write (once a second while
        // playing), so anything it does not carry is gone within a second.
        let carried = form ?? existing.flatMap { markedForm($0) }
        return entry(position: position, duration: known, nowMs: nowMs, form: carried)
    }

    /// **Supplementing:** add ONLY the missing reference point to an entry
    /// that already exists. Position and timestamp stay untouched. This is
    /// not a merge and not an adoption, which is why it asks no question about
    /// timestamps: for the affected episodes both sides stem from the SAME
    /// event, so the server is never newer.
    ///
    /// `nil` means "nothing to do": the entry already has one, or the other
    /// side knows no duration. An entry is NEVER created from nothing. A
    /// repair that resurrects deleted state is the class the subscription
    /// merge guards against with its mass-deletion check.
    static func supplementing(_ existing: [Double], duration: Double) -> [Double]? {
        guard duration > 0, existing.count >= 2, markedDuration(existing) == nil else { return nil }
        if let form = markedForm(existing) {
            return [existing[0], existing[1], duration, form.rawValue]
        }
        return [existing[0], existing[1], duration]
    }

    /// **The stock repair.** `supplementing` above needs someone who KNOWS the
    /// duration an entry was written against. The server states it in its
    /// action. For everything that never appears in such an action there is a
    /// second, weaker but sufficient witness: the position itself.
    ///
    /// An entry that stands exactly at a duration was written when that
    /// duration was reached. Nothing else produces that value. So where the
    /// entry reads as finished against today's duration, today's duration IS
    /// the one it was written against, and it may be recorded.
    ///
    /// Everything in between stays untouched: for a half-heard episode nobody
    /// can say which duration applied, and a guess would be exactly the
    /// invention this type exists to prevent. The sentinel is excluded too.
    /// It needs no reference point, it was never written against a duration.
    ///
    /// The threshold is the TRUE end (`reachedEnd`), never the person's
    /// choice: only a position at the end was written against that duration;
    /// one a minute before it was not, and recording one there would guess.
    static func supplementingFinished(_ stored: [Double], duration: Double) -> [Double]? {
        guard let position = stored.first, duration > 0 else { return nil }
        guard position < playedSentinel, reachedEnd(position: position, duration: duration) else { return nil }
        return supplementing(stored, duration: duration)
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

    /// The duration that applied when the entry was written. If it carries one.
    static func markedDuration(_ stored: [Double]) -> Double? {
        stored.count >= 3 && stored[2] > 0 ? stored[2] : nil
    }

    /// Three states of an episode for the UI. Unplayed, in progress (with a
    /// remaining time) or fully played. Foundation-only on purpose: the
    /// decision below belongs next to the mark it reads, not to a view.
    enum PlayState: Equatable, Sendable {
        case unplayed
        case inProgress(fraction: Double, remaining: Double)
        case played

        /// The class without the moving numbers. The tile counts and the
        /// sections read only this; comparing whole states between two
        /// ticks of playback saw a new value every five seconds and had
        /// the podcast tab recompute all its shows each time.
        var phase: Phase {
            switch self {
            case .unplayed: return .unplayed
            case .inProgress: return .inProgress
            case .played: return .played
            }
        }

        enum Phase: Equatable, Sendable {
            case unplayed, inProgress, played
        }
    }

    /// THE answer to "how far is this episode". Both the reactive store and
    /// the off-main sections compute call this. They used to carry two
    /// versions of it with the same signature, and only one of them knew
    /// about the marked duration. That is why a healed entry stayed invisible
    /// in exactly the two surfaces that show the symptom.
    static func state(stored: [Double]?, currentDuration: Double, tail: Double) -> PlayState {
        guard let stored, stored.count >= 2 else { return .unplayed }
        if isPlayed(stored: stored, currentDuration: currentDuration, tail: tail) { return .played }
        guard currentDuration > 0 else { return .unplayed }
        let time = stored[0]
        guard time > 1 else { return .unplayed }
        return .inProgress(fraction: min(max(time / currentDuration, 0), 1),
                           remaining: currentDuration - time)
    }

    /// Does the entry count as played for the person?
    ///
    /// The order is deliberate: sentinel first (it needs no duration), then the
    /// STORED duration, and only last today's. That last step is the old path
    /// and applies only to entries without a third value.
    ///
    /// `tail` is the choice from `PlayedTail`: within that many seconds of the
    /// end counts as played. It only READS; the mark stays where it is, so
    /// the last minute can still be heard and nothing is rewritten.
    static func isPlayed(stored: [Double], currentDuration: Double, tail: Double) -> Bool {
        guard let position = stored.first else { return false }
        if position >= playedSentinel { return true }
        if let marked = markedDuration(stored) { return withinTail(position: position, duration: marked, tail: tail) }
        return withinTail(position: position, duration: currentDuration, tail: tail)
    }

    /// Within `tail` seconds of the end. The last second always counts:
    /// the final tick rarely lands exactly on the duration. The tail is at
    /// most a tenth of the length: "almost finished" is the end, and a
    /// two-minute item must not count as played after its first minute.
    static func withinTail(position: Double, duration: Double, tail: Double) -> Bool {
        duration > 0 && position >= duration - max(min(tail, duration * tailShareCap), trueEndTolerance)
    }

    /// The largest share of a title the tail may cover.
    static let tailShareCap: Double = 0.1

    /// Has the position reached the TRUE end? What goes to a server as
    /// finished, and what a repair may treat as "written at the end", asks
    /// this and never the person's choice: a server learns "finished" at the
    /// end as before, and a repair must not guess.
    static func reachedEnd(position: Double, duration: Double) -> Bool {
        withinTail(position: position, duration: duration, tail: 0)
    }

    /// The tolerance of `reachedEnd`, one second.
    static let trueEndTolerance: Double = 1

    /// The played question at the true end, for an entry: what a server is
    /// told and what decides a restart on a deliberate play.
    static func reachedEnd(stored: [Double], currentDuration: Double) -> Bool {
        isPlayed(stored: stored, currentDuration: currentDuration, tail: 0)
    }

    /// The one direction a played or finished toggle offers.
    enum MarkGesture: Equatable, Sendable {
        case markPlayed
        case markUnplayed

        /// Whether carrying out the gesture marks the title played.
        var marksPlayed: Bool { self == .markPlayed }
    }

    /// Which toggle a title offers. It asks the TRUE end (or a server's
    /// finished flag), the same question a deliberate Play asks, never the
    /// person's tail: between the tail and the true end the title shows as
    /// played, and the toggle there marks it played and writes the end. A
    /// toggle that read what the row shows offered "unplayed" there and
    /// wrote 0 over the last minute.
    static func markGesture(atTrueEnd: Bool) -> MarkGesture {
        atTrueEnd ? .markUnplayed : .markPlayed
    }

    /// The state from a SERVER's progress (an Audiobookshelf episode): its
    /// flag, or a fraction within the tail, is played. One translation for
    /// every reader of that progress.
    static func serverState(isFinished: Bool, fraction: Double, duration: Double, tail: Double) -> PlayState {
        if isFinished { return .played }
        guard fraction > 0.001 else { return .unplayed }
        if withinTail(position: duration * fraction, duration: duration, tail: tail) { return .played }
        let remaining = duration > 0 ? duration * (1 - fraction) : 0
        return .inProgress(fraction: min(max(fraction, 0), 1), remaining: remaining)
    }

    /// Whole minutes left for a remaining time, rounded UP: under a minute
    /// reads "1 min", never "0 min".
    static func minutesLeft(_ remaining: Double) -> Int {
        let remaining = PodcastDuration.known(remaining)
        guard remaining > 0 else { return 0 }
        return Int((remaining / 60).rounded(.up))
    }
}

/// The name the UI has always used. One type, one decision. The alias keeps
/// the call sites untouched while the truth lives in `ProgressMark`.
typealias EpisodePlayState = ProgressMark.PlayState
