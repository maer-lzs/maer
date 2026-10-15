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
    }

    private let state = Mutex(State())
    private let open: (@Sendable () async throws -> StandStore)?
    /// The tables read synchronously, for the start of the stock; nil when
    /// this mirror has none (a witness over a memory table).
    private let loadNow: (@Sendable () throws -> ListeningStore.Stock?)?

    init() {
        let database = MaerDatabase.shared
        open = { try await StandStore(connection: try database.connection()) }
        loadNow = {
            guard let reader = try database.readerNow() else { return nil }
            return try StandStore.loadNow(reader: reader)
        }
    }

    /// A mirror over a given table, for witnesses; `loadNow` reads the same
    /// file synchronously when the witness asks for the move.
    init(store: StandStore, loadNow: (@Sendable () throws -> ListeningStore.Stock?)? = nil) {
        open = nil
        self.loadNow = loadNow
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
    /// counts again.
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
        let legacy = ListeningStore.legacyEntries(in: defaults)
        let entries = ListeningStore.positions(in: defaults)
        let flushed = ListeningStore.allFlushed(in: defaults)
        enqueue { store in
            if !moved {
                let written = try await store.importEntries(entries)
                let removed = try await store.retainOnly(Set(entries.keys))
                let pushed = try await store.replaceFlushed(with: flushed)
                Logger.library.notice("STAND repair written=\(written) removed=\(removed) flushedWritten=\(pushed.written) flushedRemoved=\(pushed.removed) resumed=\(resumes)")
                if movesNow { ListeningStore.markMoved(for: followed) }
            }
            guard movesNow || moved,
                  !legacy.backups.isEmpty || !legacy.flushed.isEmpty else { return }
            let table = ListeningStore.Stock(backups: try await store.all().mapValues(\.entry),
                                             flushed: try await store.allFlushed())
            let check = ListeningStore.legacyCovered(legacy: legacy, table: table)
            ListeningStore.retireLegacyKeys(check.retire, for: followed)
            Logger.library.notice("STAND old keys retired=\(check.retire.backups.count) flushed=\(check.retire.flushed.count)")
            if !check.missing.isEmpty {
                Logger.library.error("STAND old keys kept missing=\(check.missing.count) of=\(legacy.backups.count + legacy.flushed.count)")
            }
        }
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

    /// What the whole write of an open replacement did before a write ran.
    private enum Whole {
        /// No replacement was open.
        case none
        /// It landed now, with the travelling part as it stands: a write of
        /// a travelling id is in it already.
        case landed(travels: @Sendable (String) -> Bool)
        /// It could not land; it stays open, is tried again with the next
        /// write, and every write runs as it is.
        case held
    }

    /// The open replacement written whole, if one is open.
    private func writeOpenReplacement(_ store: StandStore) async -> Whole {
        guard let pending = state.withLock({ state in
            state.replacement.flatMap { open in state.followed.map { (open, $0) } }
        }) else { return .none }
        let (open, followed) = pending
        guard let stock = ListeningStore.resting(where: open.travels, of: followed) else {
            Logger.library.error("STAND replacement held, tried again with the next write: the stock is not loaded")
            return .held
        }
        do {
            try await store.replaceTravelling(backups: stock.backups, flushed: stock.flushed, travels: open.travels,
                                              also: OwnerMark.statements(family: open.family, replacement: open.name))
        } catch {
            Logger.library.error("STAND replacement held, tried again with the next write reason=\(String(describing: error), privacy: .public)")
            return .held
        }
        state.withLock { if $0.replacement?.name == open.name { $0.replacement = nil } }
        open.landed()
        return .landed(travels: open.travels)
    }

    /// One write of what this device last pushed: an entry, or nil for a removal.
    func noteFlushed(itemId: String, entry: [Double]?, in written: ObjectIdentifier) {
        guard state.withLock({ $0.followed }) == written else { return }
        enqueue(itemId: itemId) { store in
            if let entry {
                try await store.upsertFlushed(itemId: itemId, entry: entry)
            } else {
                try await store.removeFlushed(itemId: itemId)
            }
        }
    }

    /// One write of the stock: an entry, or nil for a removal.
    func note(itemId: String, entry: [Double]?, in written: ObjectIdentifier) {
        guard state.withLock({ $0.followed }) == written else { return }
        enqueue(itemId: itemId) { store in
            if let entry, let stand = Stand(itemId: itemId, entry: entry) {
                try await store.upsert(stand)
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

    /// The table, for a carrier that reads rows. Nil when opening failed
    /// (logged per attempt).
    func standStore() async -> StandStore? {
        await openIfNeeded()
    }

    /// One write in the chain. While a replacement is open its whole write
    /// goes first; the write itself then runs, unless it is of a travelling
    /// id (`itemId`) the whole write just carried as it stands now.
    private func enqueue(itemId: String? = nil, _ work: @escaping @Sendable (StandStore) async throws -> Void) {
        state.withLock { state in
            let previous = state.pendingWrite
            state.pendingWrite = Task { [self] in
                await previous?.value
                guard let store = await openIfNeeded() else { return }
                if case .landed(let travels) = await self.writeOpenReplacement(store),
                   let itemId, travels(itemId) { return }
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
