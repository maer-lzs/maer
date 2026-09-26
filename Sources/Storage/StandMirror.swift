// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation
import OSLog
import Synchronization

/// The row copy of the local listening stock.
///
/// The defaults stay the synchronous stock every reader asks (`ListeningStore`
/// is an accessor over those keys, and forty surfaces read it without an
/// await). What changes: every write to a position also lands in the `stand`
/// table, in the order it was made, and the start pours the whole stock into
/// the table once. So the rows are complete from the first launch on, and a
/// carrier that speaks rows (Mär-Sync, CloudKit) reads the table instead of
/// scanning the defaults.
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
    }

    private let state = Mutex(State())
    private let open: (@Sendable () async throws -> StandStore)?

    init() {
        open = { try await StandStore(connection: try MaerDatabase.shared.connection()) }
    }

    /// A mirror over a given table, for witnesses.
    init(store: StandStore) {
        open = nil
        state.withLock { $0.store = store }
    }

    /// Installs the mirror on the stock and pours the defaults in. Once, at
    /// app start; the import is idempotent, so a second start costs one
    /// transaction and writes nothing.
    func start(defaults: UserDefaults = .standard) {
        let followed = ObjectIdentifier(defaults)
        state.withLock { $0.followed = followed }
        ListeningStore.onWrite = { [weak self] itemId, entry, written in
            self?.note(itemId: itemId, entry: entry, in: written)
        }
        ListeningStore.onFlushedWrite = { [weak self] itemId, entry, written in
            self?.noteFlushed(itemId: itemId, entry: entry, in: written)
        }
        let entries = ListeningStore.positions(in: defaults)
        let flushed = ListeningStore.allFlushed(in: defaults)
        enqueue { store in
            // The rows follow the stock exactly: newer entries in (a
            // tombstone is an entry, its moment decides), and a row whose
            // title the stock no longer holds goes, because the defaults are
            // still written first and so know every removal first.
            let written = try await store.importEntries(entries)
            let removed = try await store.retainOnly(Set(entries.keys))
            let pushed = try await store.replaceFlushed(with: flushed)
            Logger.library.notice("STAND repair written=\(written) removed=\(removed) flushedWritten=\(pushed.written) flushedRemoved=\(pushed.removed)")
        }
    }

    /// One write of what this device last pushed: an entry, or nil for a removal.
    func noteFlushed(itemId: String, entry: [Double]?, in written: ObjectIdentifier) {
        guard state.withLock({ $0.followed }) == written else { return }
        enqueue { store in
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
        enqueue { store in
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

    private func enqueue(_ work: @escaping @Sendable (StandStore) async throws -> Void) {
        state.withLock { state in
            let previous = state.pendingWrite
            state.pendingWrite = Task { [self] in
                await previous?.value
                guard let store = await openIfNeeded() else { return }
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
