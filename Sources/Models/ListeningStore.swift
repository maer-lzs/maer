// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation
import OSLog

/// What a "local state" MEANS for a class of items. Not every id that can be
/// played has a position: a live stream has no end to be at, so a growing
/// number would be an invented fact that any future surface scanning the
/// stock would then read as progress.
nonisolated enum ListeningClasses {
    /// Ids whose local state is a POSITION. Everything the player can resume.
    static func keepsPosition(_ itemId: String) -> Bool {
        !isLive(itemId)
    }

    /// A live stream. Its local state is "when did I last listen", which the
    /// radio store keeps; a position would be meaningless and misleading.
    static func isLive(_ itemId: String) -> Bool {
        itemId.hasPrefix("radio:")
    }
}

/// THE local listening stock: every class writes here, every reading surface
/// asks here.
///
/// **The invariant:** what you listen to always stands on
/// the device too. Every class, every source, downloaded or streamed. The
/// server is a sync MEDIUM and a messenger between devices, never the sole
/// owner, and no sync may ever remove a local state without replacement.
///
/// Deliberately an ACCESSOR over the existing keys, not a new format: the
/// podcast iCloud sync reads exactly these keys and this array shape, so a new
/// layout would break it silently across devices. And it would make every
/// user's stock a migration.
///
/// The point of the type is OWNERSHIP: the keys and the interpretation of the
/// `[Double]` shape live here. Call sites ask for values with names, so nobody
/// indexes `stored[1]` themselves again. That indexing is where the "`.last`
/// is the duration, not the timestamp" class of bugs came from.
/// An `enum` with static functions, not an instance: `UserDefaults` is not
/// `Sendable` under Swift 6, so a shared instance would need an
/// `@unchecked` escape. And the project keeps that count at zero. The store
/// to work on travels as a parameter instead, which is also what lets a test
/// use its own suite.
nonisolated enum ListeningStore {

    /// One local state, with names instead of indices.
    struct Mark: Equatable {
        let position: Double
        /// Milliseconds since 1970. An epoch, never a formatted string:
        /// zones exist in the display only.
        let updatedAtMs: Double
        /// The length this entry was written against, when it is known.
        let duration: Double?
        /// Which key answered. The crash backup or the flushed witness.
        let source: Source

        enum Source: Equatable {
            /// The per-second backup the player keeps while playing.
            case backup
            /// What this device last pushed to a server. Proof of having
            /// started even when every server-fed value says otherwise.
            case flushed
        }
    }

    // MARK: - Reading

    /// The best local witness for an id, whichever key holds it. The backup
    /// leads when both exist: it is the fresher statement by construction (the
    /// flushed one is written when the backup is retired).
    static func mark(_ itemId: String, in defaults: UserDefaults = .standard) -> Mark? {
        if let stored = backup(itemId, in: defaults),
           let mark = mark(from: stored, source: .backup) {
            return mark
        }
        guard let stored = flushed(itemId, in: defaults) else { return nil }
        return mark(from: stored, source: .flushed)
    }

    static func position(_ itemId: String, in defaults: UserDefaults = .standard) -> Double? {
        mark(itemId, in: defaults)?.position
    }

    /// The raw entry. For the sync paths that hand the array on unchanged
    /// (iCloud blob, gpodder). Reading surfaces use `mark(_:)` instead.
    static func backup(_ itemId: String, in defaults: UserDefaults = .standard) -> [Double]? {
        defaults.array(forKey: AppStorageKeys.localPosition(itemId)) as? [Double]
    }

    static func flushed(_ itemId: String, in defaults: UserDefaults = .standard) -> [Double]? {
        defaults.array(forKey: AppStorageKeys.flushedPosition(itemId)) as? [Double]
    }

    static func mark(from stored: [Double], source: Mark.Source) -> Mark? {
        guard stored.count >= 2 else { return nil }
        return Mark(position: stored[0], updatedAtMs: stored[1],
                    duration: ProgressMark.markedDuration(stored), source: source)
    }

    // MARK: - Writing

    /// Record a position. `advancing` carries a known duration forward, so an
    /// entry that knows its reference point never loses it to a caller that
    /// does not.
    static func record(_ itemId: String, position: Double, duration: Double,
                       atMs: Double, in defaults: UserDefaults = .standard) {
        guard ListeningClasses.keepsPosition(itemId) else { return }
        // A position only comes into being while listening, so this is where a
        // not-subscribed episode is written down. Listened ones only, never
        // browsed ones: otherwise the position would outlive its resolution and
        // the tile would carry no name. Idempotent, so the per-second tick
        // costs nothing.
        BrowsedEpisodes.shared.keepListened(guid: itemId, defaults: defaults)
        // Heard here: an imported position becomes this device's own.
        ForeignMarks.clearImported(itemId, in: defaults)
        let key = AppStorageKeys.localPosition(itemId)
        defaults.set(ProgressMark.advancing(defaults.array(forKey: key) as? [Double],
                                            position: position, duration: duration,
                                            nowMs: atMs),
                     forKey: key)
    }

    /// What this device pushed, and when. Written INSTEAD of removing the
    /// backup after a successful sync. A deleted witness is not a fact.
    static func noteFlushed(_ itemId: String, position: Double, atMs: Double,
                            in defaults: UserDefaults = .standard) {
        defaults.set([position, atMs], forKey: AppStorageKeys.flushedPosition(itemId))
    }

    /// Store an entry a RULE produced. The healing paths (gpodder supplement,
    /// Apple import adoption, duration repair) decide with `ProgressMark` and
    /// hand the finished entry over. Named rather than raw, so the fence can
    /// tell "a rule wrote this" from "a call site indexed the shape itself".
    static func store(_ itemId: String, entry: [Double],
                      in defaults: UserDefaults = .standard) {
        guard ListeningClasses.keepsPosition(itemId), entry.count >= 2 else { return }
        // Third write path for a position, so it carries the same rule as the
        // two above: a position must not outlive its resolution. Marking an
        // episode as played by hand writes the end position through here, and
        // without this the tile would carry no name. A zero entry is the
        // unplayed tombstone and states the opposite, so it writes nothing
        // down.
        if entry[0] > 0 {
            BrowsedEpisodes.shared.keepListened(guid: itemId, defaults: defaults)
        } else {
            // The tombstone forgets what another app knew about the episode.
            ForeignMarks.clear(itemId, in: defaults)
        }
        defaults.set(entry, forKey: AppStorageKeys.localPosition(itemId))
    }

    /// Record WHAT an item was started as. Called once at playback start, from
    /// the source that knows. Never derived later, because the fact that
    /// answers it (the item's collections) is only warm while the item is
    /// loaded.
    ///
    /// Writes onto the existing entry when there is one, and creates a minimal
    /// one otherwise: the row that reads this needs an entry to hang a time on,
    /// and the position tick would create it a second later anyway. Position 0
    /// reads as "unplayed" everywhere, so nothing is invented.
    static func noteStartedForm(_ itemId: String, form: ProgressMark.StartedForm,
                                atMs: Double, in defaults: UserDefaults = .standard) {
        guard ListeningClasses.keepsPosition(itemId) else { return }
        // Playback start is the earliest moment at which "this was listened to"
        // is true. Same rule as in `record`.
        BrowsedEpisodes.shared.keepListened(guid: itemId, defaults: defaults)
        let key = AppStorageKeys.localPosition(itemId)
        let existing = defaults.array(forKey: key) as? [Double]
        defaults.set(ProgressMark.entry(position: existing?.first ?? 0,
                                        duration: existing.flatMap(ProgressMark.markedDuration) ?? 0,
                                        nowMs: existing.flatMap(ProgressMark.timestamp) ?? atMs,
                                        form: form),
                     forKey: key)
    }

    /// What an entry says it was started as. Nil when it predates this.
    static func startedForm(_ itemId: String,
                            in defaults: UserDefaults = .standard) -> ProgressMark.StartedForm? {
        backup(itemId, in: defaults).flatMap(ProgressMark.markedForm)
    }

    /// Does this id hold a local state at all? The existence question, asked
    /// without reading a shape.
    static func hasStand(_ itemId: String, in defaults: UserDefaults = .standard) -> Bool {
        backup(itemId, in: defaults) != nil
    }

    static func clearBackup(_ itemId: String, in defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: AppStorageKeys.localPosition(itemId))
    }

    // MARK: - Moving and forgetting

    /// Re-keying (an rss episode adopted by the server): the state MOVES, it
    /// is not copied over whatever the target already holds. The target wins
    /// when it is newer. Otherwise a device that already listened to the
    /// server-side twin would lose that by being re-keyed.
    static func move(from old: String, to new: String,
                     in defaults: UserDefaults = .standard) {
        guard let arriving = backup(old, in: defaults) else { return }
        let winner = newer(arriving, backup(new, in: defaults))
        defaults.set(winner, forKey: AppStorageKeys.localPosition(new))
        defaults.removeObject(forKey: AppStorageKeys.localPosition(old))
    }

    /// Newest timestamp wins; a missing side loses. Pure so the rule is
    /// testable without a store.
    static func newer(_ a: [Double], _ b: [Double]?) -> [Double] {
        guard let b, let bTime = ProgressMark.timestamp(b) else { return a }
        guard let aTime = ProgressMark.timestamp(a) else { return b }
        return aTime >= bTime ? a : b
    }

    /// The ONE legitimate removal: the user deleted the item itself, so its
    /// state has nothing left to belong to. Every other path replaces instead
    /// of removing. That is the invariant.
    static func forgetUserDeleted(_ itemId: String, in defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: AppStorageKeys.localPosition(itemId))
        defaults.removeObject(forKey: AppStorageKeys.flushedPosition(itemId))
        ForeignMarks.clear(itemId, in: defaults)
    }

    // MARK: - Scanning

    /// Every id the stock holds a backup for, with its entry. The class filter
    /// belongs here, so no surface has to remember that a live stream writes
    /// nothing worth reading.
    static func allBackups(in defaults: UserDefaults = .standard) -> [(id: String, stored: [Double])] {
        let prefix = AppStorageKeys.localPosition("")
        var out: [(id: String, stored: [Double])] = []
        for (key, value) in defaults.dictionaryRepresentation() {
            guard key.hasPrefix(prefix), let stored = value as? [Double], stored.count >= 2
            else { continue }
            let id = String(key.dropFirst(prefix.count))
            guard ListeningClasses.keepsPosition(id) else { continue }
            out.append((id, stored))
        }
        return out
    }
}
