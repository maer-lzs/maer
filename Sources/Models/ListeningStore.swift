// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation
import OSLog
import Synchronization

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
        ItemNamespace.isRadio(itemId)
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
/// Every entry keeps the `[Double]` shape it had under the defaults keys,
/// `[position, tsMs, duration?, form?]`, so the merge rules and the carriers
/// (the podcast iCloud sync, the stand carriers) read it unchanged.
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
///
/// **Readers ask memory; the table is the store.** Each position used to be
/// its own defaults key, and on a domain of tens of thousands of them any
/// read right after a write cost about 23 ms in the simulator. So the stock
/// of a defaults object is loaded ONCE and held in memory; a write goes to
/// memory and, through `onWrite`/`onFlushedWrite`, to the rows of the
/// database. The defaults keys are no longer written.
///
/// **Where the stock comes from.** The row copy installs a synchronous read
/// of its tables (`installTable`). The first start with it finds the move
/// marker absent: the old keys are then the complete stock (every build
/// before wrote them first), the rows are brought to exactly them, and the
/// marker is set once they have landed. From then on the table is the
/// stock. The old keys go only when every one of them stands in the table
/// (`legacyCovered`), each start tries again until they do, and nothing but
/// `retireLegacyKeys` removes them. Without an installed table (a test
/// suite of its own) the stock is the old keys of that object and lives in
/// memory.
nonisolated enum ListeningStore {

    /// The stock of one defaults object: position entries and what this
    /// device last pushed, by item id.
    struct Stock: Sendable, Equatable {
        var backups: [String: [Double]] = [:]
        var flushed: [String: [Double]] = [:]
    }

    /// Set in the defaults once the table holds the whole stock.
    static let movedKey = "positionsMovedToTable"

    private static let stocks = Mutex<[ObjectIdentifier: Stock]>([:])
    private static let tables = Mutex<[ObjectIdentifier: @Sendable () throws -> Stock?]>([:])

    /// The defaults objects a stock is held for, kept alive so an identity
    /// is never reused by another object. `nonisolated(unsafe)` because
    /// `UserDefaults` is not `Sendable` and cannot live in the mutex's
    /// state; read and written only inside `stocks.withLock`.
    nonisolated(unsafe) private static var anchors: [ObjectIdentifier: UserDefaults] = [:]

    /// Runs `body` on the held stock of `defaults`, loading it first if
    /// this is the first question about that object.
    private static func withStock<T: Sendable>(_ defaults: UserDefaults, _ body: (inout Stock) -> T) -> T {
        stocks.withLock { all in
            let id = ObjectIdentifier(defaults)
            if all[id] == nil {
                all[id] = load(defaults)
                anchors[id] = defaults
            }
            return body(&all[id]!)
        }
    }

    /// The stock at its first question: the table once the move is done,
    /// the old keys before it or without a table.
    private static func load(_ defaults: UserDefaults) -> Stock {
        let legacy = loadFromDefaults(defaults)
        guard let table = tables.withLock({ $0[ObjectIdentifier(defaults)] }),
              defaults.bool(forKey: movedKey) else { return legacy }
        do {
            guard let rows = try table() else {
                Logger.library.error("STAND load: moved, but the database is empty; the old keys answer")
                return legacy
            }
            return rows
        } catch {
            Logger.library.error("STAND load failed reason=\(FailureReason.of(error), privacy: .public); the old keys answer")
            return legacy
        }
    }

    /// The row copy's synchronous read, for the stock of `defaults`. A stock
    /// already held is dropped, so the next question loads through it.
    static func installTable(for defaults: UserDefaults, load: @escaping @Sendable () throws -> Stock?) {
        tables.withLock { $0[ObjectIdentifier(defaults)] = load }
        stocks.withLock { $0[ObjectIdentifier(defaults)] = nil }
    }

    /// Whether the table is the stock of `defaults`.
    static func isMoved(in defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: movedKey)
    }

    /// The old keys as they lie, for the move.
    static func legacyEntries(in defaults: UserDefaults = .standard) -> Stock {
        loadFromDefaults(defaults)
    }

    /// Marks the move done for the defaults object `owner` names, once the
    /// rows hold the stock.
    static func markMoved(for owner: ObjectIdentifier) {
        stocks.withLock { _ in anchors[owner]?.set(true, forKey: movedKey) }
    }

    /// Whether every old entry stands in the table: the same entry, or a
    /// newer one (a moment is the only order; a tombstone is an entry like
    /// any other). An old entry that is no listening state (fewer than two
    /// numbers, or a live stream) carries nothing to lose and is not asked.
    static func legacyCovered(legacy: Stock, table: Stock) -> (covered: Bool, missing: [String]) {
        var missing: [String] = []
        func holds(_ old: [Double], _ new: [Double]?) -> Bool {
            guard let new else { return false }
            if new == old { return true }
            guard let oldTime = ProgressMark.timestamp(old), let newTime = ProgressMark.timestamp(new) else { return false }
            return newTime > oldTime
        }
        for (id, entry) in legacy.backups
        where entry.count >= 2 && ListeningClasses.keepsPosition(id) && !holds(entry, table.backups[id]) {
            missing.append(id)
        }
        for (id, entry) in legacy.flushed where entry.count >= 2 {
            let new = table.flushed[id]
            if new != Array(entry.prefix(2)) && !((new?[1] ?? -1) > entry[1]) { missing.append("flushed \(id)") }
        }
        return (missing.isEmpty, missing.sorted())
    }

    /// Removes the old keys of `legacy` from the defaults object `owner`
    /// names: the one place the old keys are removed, and it is called only
    /// once the table was found to cover them.
    static func retireLegacyKeys(_ legacy: Stock, for owner: ObjectIdentifier) {
        // Taken under the lock, used outside it: removing tens of thousands
        // of keys took about 0.45 ms each in the simulator, seconds in all,
        // and the readers must not wait for it. `UserDefaults` is safe to
        // use from any thread; the one reason it cannot leave the lock
        // plainly is that the SDK does not mark it `Sendable`.
        nonisolated(unsafe) let defaults = stocks.withLock { _ in anchors[owner] }
        guard let defaults else { return }
        for id in legacy.backups.keys { defaults.removeObject(forKey: AppStorageKeys.localPosition(id)) }
        for id in legacy.flushed.keys { defaults.removeObject(forKey: AppStorageKeys.flushedPosition(id)) }
    }

    /// The one read of the position keys from the defaults: the whole old
    /// stock, every entry as it lies (the filters belong to the questions,
    /// as they did when each question read its key).
    private static func loadFromDefaults(_ defaults: UserDefaults) -> Stock {
        let backupPrefix = AppStorageKeys.localPosition("")
        let flushedPrefix = AppStorageKeys.flushedPosition("")
        var stock = Stock()
        for (key, value) in defaults.dictionaryRepresentation() {
            // The sync accepted numbers of any kind here; so does the stock,
            // or an entry the pot carried would vanish from it.
            guard let stored = (value as? [Double]) ?? (value as? [NSNumber])?.map(\.doubleValue)
            else { continue }
            if key.hasPrefix(backupPrefix) {
                stock.backups[String(key.dropFirst(backupPrefix.count))] = stored
            } else if key.hasPrefix(flushedPrefix) {
                stock.flushed[String(key.dropFirst(flushedPrefix.count))] = stored
            }
        }
        return stock
    }

    /// The row copy listens here: every write of a position (an entry, or
    /// nil for a removal) is announced with the defaults it went into, by
    /// identity. Installed once at app start by the mirror, nil in a test
    /// that does not ask for it. A hook rather than a call into the row
    /// backend, so this file keeps to Foundation and the direction of the
    /// dependency stays Storage to Models.
    /// unsafe because: set once at app start, only read afterwards.
    nonisolated(unsafe) static var onWrite: (@Sendable (_ itemId: String, _ entry: [Double]?,
                                                        _ defaults: ObjectIdentifier) -> Void)?

    /// The one place a position write is announced from. Every path that
    /// touches the `localPosition` key of a title ends here.
    private static func announce(_ itemId: String, _ entry: [Double]?, in defaults: UserDefaults) {
        onWrite?(itemId, entry, ObjectIdentifier(defaults))
    }

    /// The same for what this device last pushed (`flushedPosition`).
    /// unsafe because: set once at app start, only read afterwards.
    nonisolated(unsafe) static var onFlushedWrite: (@Sendable (_ itemId: String, _ entry: [Double]?,
                                                               _ defaults: ObjectIdentifier) -> Void)?

    private static func announceFlushed(_ itemId: String, _ entry: [Double]?, in defaults: UserDefaults) {
        onFlushedWrite?(itemId, entry, ObjectIdentifier(defaults))
    }

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
        withStock(defaults) { $0.backups[itemId] }
    }

    static func flushed(_ itemId: String, in defaults: UserDefaults = .standard) -> [Double]? {
        withStock(defaults) { $0.flushed[itemId] }
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
        let entry = withStock(defaults) { stock in
            let entry = ProgressMark.advancing(stock.backups[itemId],
                                               position: position, duration: duration,
                                               nowMs: atMs)
            stock.backups[itemId] = entry
            return entry
        }
        announce(itemId, entry, in: defaults)
    }

    /// What this device pushed, and when. Written INSTEAD of removing the
    /// backup after a successful sync. A deleted witness is not a fact.
    static func noteFlushed(_ itemId: String, position: Double, atMs: Double,
                            in defaults: UserDefaults = .standard) {
        withStock(defaults) { stock in
            stock.flushed[itemId] = [position, atMs]
        }
        announceFlushed(itemId, [position, atMs], in: defaults)
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
        withStock(defaults) { stock in
            stock.backups[itemId] = entry
        }
        announce(itemId, entry, in: defaults)
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
        let entry = withStock(defaults) { stock in
            let existing = stock.backups[itemId]
            let entry = ProgressMark.entry(position: existing?.first ?? 0,
                                           duration: existing.flatMap(ProgressMark.markedDuration) ?? 0,
                                           nowMs: existing.flatMap(ProgressMark.timestamp) ?? atMs,
                                           form: form)
            stock.backups[itemId] = entry
            return entry
        }
        announce(itemId, entry, in: defaults)
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
        withStock(defaults) { stock in
            stock.backups[itemId] = nil
        }
        announce(itemId, nil, in: defaults)
    }

    // MARK: - Moving and forgetting

    /// Re-keying (an rss episode adopted by the server): the state MOVES, it
    /// is not copied over whatever the target already holds. The target wins
    /// when it is newer. Otherwise a device that already listened to the
    /// server-side twin would lose that by being re-keyed.
    static func move(from old: String, to new: String,
                     in defaults: UserDefaults = .standard) {
        let winner: [Double]? = withStock(defaults) { stock in
            guard let arriving = stock.backups[old] else { return nil }
            let winner = newer(arriving, stock.backups[new])
            stock.backups[new] = winner
            stock.backups[old] = nil
            return winner
        }
        guard let winner else { return }
        announce(new, winner, in: defaults)
        announce(old, nil, in: defaults)
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
        withStock(defaults) { stock in
            stock.backups[itemId] = nil
            stock.flushed[itemId] = nil
        }
        announce(itemId, nil, in: defaults)
        announceFlushed(itemId, nil, in: defaults)
        ForeignMarks.clear(itemId, in: defaults)
    }

    /// Removes the backups whose ids `shouldForget` names, as the cleanup of
    /// titles that no longer exist asks. Each removal is announced like any
    /// other, so the row copy follows.
    static func forgetBackups(where shouldForget: (String) -> Bool,
                              in defaults: UserDefaults = .standard) {
        let gone: [String] = withStock(defaults) { stock in
            let ids = stock.backups.keys.filter(shouldForget)
            for id in ids {
                stock.backups[id] = nil
            }
            return ids
        }
        for id in gone { announce(id, nil, in: defaults) }
    }

    // MARK: - Scanning

    /// Every id the stock holds a backup for, with its entry. The class filter
    /// belongs here, so no surface has to remember that a live stream writes
    /// nothing worth reading.
    static func allBackups(in defaults: UserDefaults = .standard) -> [(id: String, stored: [Double])] {
        positions(in: defaults).map { (id: $0.key, stored: $0.value) }
    }

    /// The same as a map, for the scanners that used to walk the whole
    /// defaults domain for the `localPosition.` keys.
    static func positions(in defaults: UserDefaults = .standard) -> [String: [Double]] {
        withStock(defaults) { stock in
            stock.backups.filter { $0.value.count >= 2 && ListeningClasses.keepsPosition($0.key) }
        }
    }

    /// The position entries of a passed dictionary in the defaults' shape,
    /// by item id: for the pure rules whose witnesses hand one in. Reads no
    /// defaults.
    static func positions(inDictionary dictionary: [String: Any]) -> [String: [Double]] {
        let prefix = AppStorageKeys.localPosition("")
        var out: [String: [Double]] = [:]
        for (key, value) in dictionary where key.hasPrefix(prefix) {
            if let stored = value as? [Double] { out[String(key.dropFirst(prefix.count))] = stored }
        }
        return out
    }

    /// Every pushed witness, for the row copy.
    static func allFlushed(in defaults: UserDefaults = .standard) -> [String: [Double]] {
        withStock(defaults) { $0.flushed }
    }
}
