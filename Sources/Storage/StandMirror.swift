// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation
import OSLog
import Synchronization

/// The rows of the local listening stock: the `stand` and `stand_flushed`
/// tables are where it is kept.
///
/// Readers ask `ListeningStore`'s memory without an await; that memory is
/// loaded from the tables at start (from the old defaults keys once, on the
/// first start of this build). Every write lands here, in the order it was
/// made, and a carrier that speaks rows (Mär-Sync, CloudKit) reads the table.
///
/// Serialized on purpose: a record followed by a clear must land as a clear.
/// The writes chain on one task, the same way the Ablage callers hold their
/// `pendingWrite`. Nothing here runs synchronously on the caller: the hook
/// only appends to the chain. The database opens inside the chain, so the
/// app start pays nothing for it. Nonisolated: the hook fires wherever the
/// stock is written, and the chain is the only state, behind a mutex.
nonisolated final class StandMirror: Sendable {
    static let shared = StandMirror()

    private struct State {
        var store: StandStore?
        var pendingWrite: Task<Void, Never>?
        /// The defaults this mirror follows, by identity. A write into another
        /// instance (a test suite of its own) is not this stock.
        var followed: ObjectIdentifier?
        /// A replacement of the stock whose write with its mark has not
        /// landed: every write until then is that whole write.
        var replacement: ListeningStore.Replacement?
        /// How many writes were handed to the chain; a write's number is
        /// its place among them.
        var handed = 0
        /// The whole writes that landed, each with the number of writes
        /// handed over when it read the stock, and what travelled in it.
        var wholes: [(readAfter: Int, travels: @Sendable (String) -> Bool)] = []
        /// The stock of this run was not read from the table (its read
        /// failed, or the move mark reads unset over a table with rows): a
        /// write may add what is newer than its row, nothing goes.
        var unread = false

        /// Whether a whole write carries what the write numbered `index`
        /// wrote for `itemId`: it read the stock after that write was
        /// handed over, and the id travels in it. The stock is written
        /// before its write is handed over, so such a whole holds the
        /// entry as it stands now, and the write's own entry may belong to
        /// the account before (several writes queued at a change of account
        /// all lie behind the one that lands the whole). Wholes read before
        /// this write carry nothing for it or for any later one, and go.
        mutating func whole(carries itemId: String, writtenAt index: Int) -> Bool {
            wholes.removeAll { $0.readAfter <= index }
            return wholes.contains { $0.travels(itemId) }
        }
    }

    private let state = Mutex(State())
    private let open: (@Sendable () async throws -> StandStore)?
    /// The tables read synchronously, for the start of the stock; nil when
    /// this mirror has none (a witness over a memory table).
    private let loadNow: (@Sendable () throws -> ListeningStore.Stock?)?
    /// Awaited by every write before it runs; nil but in a witness, which
    /// holds the chain with it to queue writes behind one another.
    private let gate: (@Sendable () async -> Void)?

    init() {
        let database = MaerDatabase.shared
        open = { try await StandStore(connection: try database.connection()) }
        loadNow = {
            guard let reader = try database.readerNow() else { return nil }
            return try StandStore.loadNow(reader: reader)
        }
        gate = nil
    }

    /// A mirror over a given table, for witnesses; `loadNow` reads the same
    /// file synchronously when the witness asks for the move, `gate` holds
    /// the chain until the witness opens it.
    init(store: StandStore, loadNow: (@Sendable () throws -> ListeningStore.Stock?)? = nil,
         gate: (@Sendable () async -> Void)? = nil) {
        open = nil
        self.loadNow = loadNow
        self.gate = gate
        state.withLock { $0.store = store }
    }

    /// Installs the mirror on the stock, once at app start.
    ///
    /// Before the move (no marker) the old keys are the stock; the rows are
    /// brought to exactly them (newer entries in, a tombstone is an entry,
    /// rows without a key go), and once that has landed the marker is set:
    /// from the next load on, the table is the stock. The first such start
    /// records that the move began before it writes anything. A start that
    /// finds that record without the marker follows one that broke off: its
    /// rows may hold entries the old keys lack, so the stock is both (newer
    /// wins), and bringing the rows to that stock takes none of them. After
    /// the move the rows are the stock already.
    /// Either way an old key goes only when the table covers its entry; a
    /// key it does not cover stays, a line says how many, and the next start
    /// counts again. A resuming start whose read of the table failed holds
    /// the old keys alone, which lack what the broken start wrote: it
    /// repairs nothing, sets no marker and retires no key, and the next
    /// start resumes again.
    func start(defaults: UserDefaults = .standard) {
        let followed = ObjectIdentifier(defaults)
        state.withLock { $0.followed = followed }
        // The listener of this stock only: a mirror on another stock keeps its own.
        ListeningStore.listen(to: defaults, ListeningStore.Listener(
            wrote: { [weak self] itemId, entry in self?.note(itemId: itemId, entry: entry, in: followed) },
            wroteFlushed: { [weak self] itemId, entry in self?.noteFlushed(itemId: itemId, entry: entry, in: followed) },
            replaces: { [weak self] replacement in self?.replace(replacement, in: followed) ?? false }))
        let moved = ListeningStore.isMoved(in: defaults)
        let movesNow = loadNow != nil && !moved
        let resumes = movesNow && ListeningStore.isMoveStarted(in: defaults)
        if let loadNow { ListeningStore.installTable(for: defaults, resumes: resumes, load: loadNow) }
        if movesNow { ListeningStore.markMoveStarted(in: defaults) }
        // Before the move the old keys are the stock and are read here, once
        // per device. After it the stock is the table, and the old keys are
        // read on the chain, after the first frame.
        let startWalk: ListeningStore.Stock? = moved ? nil : Self.walkedLegacy(defaults)
        let entries = ListeningStore.positions(in: defaults)
        let flushed = ListeningStore.allFlushed(in: defaults)
        let unread = resumes && ListeningStore.readFailed(in: defaults)
        if unread || (moved && ListeningStore.readFailed(in: defaults)) {
            state.withLock { $0.unread = true }
        }
        enqueue { store in
            if unread {
                Logger.library.error("STAND repair held: the move resumes over a table it could not read")
                return
            }
            if !moved {
                // Rows at a start that neither moved nor resumes, while the
                // old keys hold nothing, were written after a move: the mark
                // read wrong. Nothing goes over them, the mark waits, and the
                // next start resumes (the record of a started move is set now).
                // Only a repair over an empty stock is refused: it would
                // remove every row. Old keys with rows beside them are the
                // ordinary first start after a build that mirrored before
                // the move.
                let rows = resumes || !entries.isEmpty || !flushed.isEmpty ? 0 : try await store.count()
                let flushedRows = resumes || !entries.isEmpty || !flushed.isEmpty ? 0 : try await store.allFlushed().count
                if rows + flushedRows > 0 {
                    self.state.withLock { $0.unread = true }
                    Logger.library.error("STAND repair refused: the table holds rows the move mark does not explain; nothing goes, the mark waits")
                    return
                }
                // A row no old key names and newer than every old key was
                // written after the move, not from those keys: the repair
                // adds and keeps everything then, it does not take what it
                // cannot explain. An older row without a key is a removal
                // the chain did not write before it ended, and goes.
                let newestOld = entries.values.compactMap { $0.count > 1 ? $0[1] : nil }.max() ?? 0
                let unnamed = resumes ? 0 : try await store.all()
                    .filter { entries[$0.key] == nil && $0.value.updatedAtMs > newestOld }.count
                let written = try await store.importEntries(entries)
                let removed = unnamed > 0 ? 0 : try await store.retainOnly(Set(entries.keys))
                if unnamed > 0 {
                    Logger.library.error("STAND repair kept \(unnamed) rows no old key names, newer than every old key: nothing removed")
                }
                let pushed = try await store.replaceFlushed(with: flushed)
                Logger.library.notice("STAND repair written=\(written) removed=\(removed) flushedWritten=\(pushed.written) flushedRemoved=\(pushed.removed) resumed=\(resumes)")
                if movesNow { ListeningStore.markMoved(for: followed) }
            }
            guard movesNow || moved else { return }
            var lastWalkMs: Double?
            let legacy: ListeningStore.Stock
            if let startWalk {
                legacy = startWalk
            } else {
                let walk = PerfSignpost.walkPositions()
                let walkStarted = ContinuousClock.now
                guard let walked = ListeningStore.legacyWalk(for: followed, nowMs: Date().timeIntervalSince1970 * 1000)
                else { walk.end(); return }
                walk.end()
                Logger.library.notice("STARTUP walk=positions ms=\(Int((ContinuousClock.now - walkStarted) / .milliseconds(1)))")
                legacy = walked.legacy
                lastWalkMs = walked.lastWalkMs
            }
            guard !legacy.backups.isEmpty || !legacy.flushed.isEmpty else { return }
            var table = ListeningStore.Stock(backups: try await store.all().mapValues(\.entry),
                                             flushed: try await store.allFlushed())
            // After the move an old key written since is listening a build
            // that writes old keys did: newer than its row, or newer than the
            // walk before when it has none, it goes into the stock. Its key
            // then is covered and goes like any other.
            if moved {
                let late = ListeningStore.lateAdoption(legacy: legacy.backups, table: table.backups, lastWalkMs: lastWalkMs)
                if !late.isEmpty {
                    let adopted = ListeningStore.adoptLate(late, for: followed)
                    for (id, entry) in late { table.backups[id] = entry }
                    Logger.library.notice("STAND old keys adopted=\(adopted) of=\(late.count)")
                }
            }
            let check = ListeningStore.legacyCovered(legacy: legacy, table: table)
            ListeningStore.retireLegacyKeys(check.retire, for: followed)
            Logger.library.notice("STAND old keys retired=\(check.retire.backups.count) flushed=\(check.retire.flushed.count)")
            if !check.missing.isEmpty {
                Logger.library.error("STAND old keys kept missing=\(check.missing.count) of=\(legacy.backups.count + legacy.flushed.count)")
            }
        }
    }

    /// The old keys read at a start before the move, measured.
    private static func walkedLegacy(_ defaults: UserDefaults) -> ListeningStore.Stock {
        let walk = PerfSignpost.walkPositions()
        let walkStarted = ContinuousClock.now
        let legacy = ListeningStore.legacyEntries(in: defaults)
        walk.end()
        Logger.library.notice("STARTUP walk=positions ms=\(Int((ContinuousClock.now - walkStarted) / .milliseconds(1)))")
        return legacy
    }

    /// A replacement of the stock at a change of account: one write of the
    /// travelling part with the replacement's mark, and every write after it
    /// is that write until it landed (`OwnerMark`).
    @discardableResult
    func replace(_ replacement: ListeningStore.Replacement, in written: ObjectIdentifier) -> Bool {
        guard state.withLock({ $0.followed }) == written else { return false }
        state.withLock { $0.replacement = replacement }
        enqueue { _ in }
        return true
    }

    /// The open replacement written whole, if one is open. Landed, it
    /// carries the travelling part as it stands when it read the stock
    /// (`State.wholes`). It may not land (the stock not loaded, a throw):
    /// then it stays open, is tried again with the next write, and every
    /// write runs as it is.
    private func writeOpenReplacement(_ store: StandStore) async {
        guard let pending = state.withLock({ state in
            state.replacement.flatMap { open in state.followed.map { (open, $0, state.handed) } }
        }) else { return }
        let (open, followed, readAfter) = pending
        guard let stock = ListeningStore.resting(where: open.travels, of: followed) else {
            Logger.library.error("STAND replacement held, tried again with the next write: the stock is not loaded")
            return
        }
        do {
            try await store.replaceTravelling(backups: stock.backups, flushed: stock.flushed, travels: open.travels,
                                              also: OwnerMark.statements(family: open.family, replacement: open.name))
        } catch {
            Logger.library.error("STAND replacement held, tried again with the next write reason=\(String(describing: error), privacy: .public)")
            return
        }
        state.withLock {
            if $0.replacement?.name == open.name { $0.replacement = nil }
            $0.wholes.append((readAfter: readAfter, travels: open.travels))
        }
        open.landed()
    }

    /// One write of what this device last pushed: an entry, or nil for a removal.
    func noteFlushed(itemId: String, entry: [Double]?, in written: ObjectIdentifier) {
        guard state.withLock({ $0.followed }) == written else { return }
        enqueue(itemId: itemId) { [self] store in
            let unread = state.withLock { $0.unread }
            if let entry {
                if unread {
                    try await store.upsertFlushedIfNewer(itemId: itemId, entry: entry)
                } else {
                    try await store.upsertFlushed(itemId: itemId, entry: entry)
                }
            } else if unread {
                Logger.library.error("STAND removal refused: the stock was not read from the table in this run")
            } else {
                try await store.removeFlushed(itemId: itemId)
            }
        }
    }

    /// One write of the stock: an entry, or nil for a removal.
    func note(itemId: String, entry: [Double]?, in written: ObjectIdentifier) {
        guard state.withLock({ $0.followed }) == written else { return }
        enqueue(itemId: itemId) { [self] store in
            let unread = state.withLock { $0.unread }
            if let entry, let stand = Stand(itemId: itemId, entry: entry) {
                if unread { try await store.upsertIfNewer(stand) } else { try await store.upsert(stand) }
            } else if unread {
                Logger.library.error("STAND removal refused: the stock was not read from the table in this run")
            } else {
                try await store.remove(itemId: itemId)
            }
        }
    }

    /// For witnesses: every write handed over so far has landed.
    func awaitPendingWrites() async {
        let pending = state.withLock { $0.pendingWrite }
        await pending?.value
    }

    /// One write in the chain. While a replacement is open its whole write
    /// goes first; the write itself then runs, unless it is of a travelling
    /// id (`itemId`) a whole write carried as it stands now, one that read
    /// the stock after this write was handed over.
    private func enqueue(itemId: String? = nil, _ work: @escaping @Sendable (StandStore) async throws -> Void) {
        state.withLock { state in
            let previous = state.pendingWrite
            let index = state.handed
            state.handed += 1
            state.pendingWrite = Task { [self] in
                await previous?.value
                await gate?()
                guard let store = await openIfNeeded() else { return }
                await self.writeOpenReplacement(store)
                if let itemId, self.state.withLock({ $0.whole(carries: itemId, writtenAt: index) }) { return }
                do {
                    try await work(store)
                } catch {
                    Logger.library.error("STAND mirror failed reason=\(String(describing: error), privacy: .public)")
                }
            }
        }
    }

    private func openIfNeeded() async -> StandStore? {
        if let store = state.withLock({ $0.store }) { return store }
        guard let open else { return nil }
        do {
            let opened = try await open()
            let rows = (try? await opened.count()) ?? -1
            Logger.library.notice("STAND open rows=\(rows)")
            state.withLock { $0.store = opened }
            return opened
        } catch {
            Logger.library.error("STAND open failed reason=\(String(describing: error), privacy: .public)")
            return nil
        }
    }
}
