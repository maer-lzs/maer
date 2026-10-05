// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation
import OSLog

/// The one write chain of a store that keeps its rows in the database, for
/// every kind of rows (a keyed table through `RowKeeper`, the podcast rows,
/// the library rows). It holds what the rows hold as far as this run knows
/// (`base`), whether the start read failed as a whole (`startReadFailed`),
/// and the serial chain: each write waits for the one before it.
///
/// Over rows the start could not read nothing is written: a write replaces
/// a row whole and nobody knows what an unread row holds. The write reads
/// the rows first (`read`); while they cannot be read it holds. Once read,
/// the store takes them into its memory (`adopt`), the base is what was
/// read, and the mark ends. The memory is taken by `take` only then, in the
/// chain after the write before and after an adoption, never at the call: a
/// picture frozen at the call would diff against a base that changed under
/// it since and remove what the base now holds.
@MainActor
final class RowChain<Snapshot> {
    /// What one write did with the rows.
    enum Outcome {
        /// The rows hold the snapshot now; the base becomes it.
        case landed
        /// Nothing was written on purpose (no change, a refused wipe).
        case skipped
    }

    /// The log prefix of the store, so a line names its owner.
    let label: String
    /// What the rows hold, as far as this run knows: the last LANDED write,
    /// the start read or a read after a failed start.
    private(set) var base: RowBase<Snapshot> = .fresh
    /// Whether the start read failed as a whole: the rows may hold anything
    /// the store's memory lacks. No write changes it; only a read that
    /// succeeds before a write does. A pass that must reach every row (the
    /// id move) waits while it holds.
    private(set) var startReadFailed = false
    /// The store's adoption of rows read after a failed start: it takes the
    /// rows into its memory by its rule. A chain without it holds every
    /// write over unread rows.
    var adopt: (@MainActor (Snapshot) -> Void)?
    /// The last handed-over write.
    private var pendingWrite: Task<Void, Never>?
    /// Writes handed over and not yet begun.
    private var waiting = 0

    init(label: String) {
        self.label = label
        RowKeepers.register(owner: self) { [weak self] in await self?.awaitPendingWrites() }
    }

    /// The outcome of the store's start read: the rows it read and how many
    /// did not decode, or a read that failed as a whole.
    func started(rows: Snapshot?, skipped: Int) {
        base = RowBase.afterLoad(rows: rows, skipped: skipped)
        startReadFailed = false
    }

    /// The start read failed as a whole: nothing read, the mark set.
    func startReadFailedAsAWhole(reason: String) {
        base = .unknown(seen: nil)
        startReadFailed = true
        Logger.library.error("\(self.label, privacy: .public) rows read failed reason=\(reason, privacy: .public) base=unknown")
    }

    /// A start read whose base the store reckons itself (a read in stages
    /// that saw part of the rows before it failed: unknown with what it
    /// saw); the mark stays off, the store holds what it saw.
    func started(base: RowBase<Snapshot>) {
        self.base = base
        startReadFailed = false
    }

    /// Hands one write to the chain. `read` reads the rows again (the rows,
    /// nil when there are none, and how many did not decode); `take` gives
    /// the store's memory, nil once the store is gone; `apply` writes the
    /// snapshot against the base and says whether it landed, and learns
    /// whether a later write is already queued (then a refused wipe of this
    /// one is no wipe attempt: the later write takes the memory anyway).
    func write(read: @escaping @MainActor () async throws -> (rows: Snapshot?, skipped: Int),
               take: @escaping @MainActor () -> Snapshot?,
               apply: @escaping @MainActor (_ snapshot: Snapshot, _ base: RowBase<Snapshot>,
                                            _ laterQueued: Bool) async throws -> Outcome) {
        let previous = pendingWrite
        waiting += 1
        pendingWrite = Task(priority: .utility) { [weak self] in
            await previous?.value
            guard let self else { return }
            self.waiting -= 1
            if self.startReadFailed {
                guard let adopt = self.adopt else {
                    Logger.library.error("\(self.label, privacy: .public) save held: rows not read and no adoption")
                    return
                }
                do {
                    let load = try await read()
                    self.base = RowBase.afterLoad(rows: load.rows, skipped: load.skipped)
                    self.startReadFailed = false
                    if let rows = load.rows { adopt(rows) }
                    Logger.library.notice("\(self.label, privacy: .public) rows read on save: skipped=\(load.skipped)")
                } catch {
                    Logger.library.notice("\(self.label, privacy: .public) save held: rows still not read reason=\(String(describing: error), privacy: .public)")
                    return
                }
            }
            guard let snapshot = take() else {
                Logger.library.notice("\(self.label, privacy: .public) save dropped: store gone")
                return
            }
            do {
                // The base is read HERE, after the write before landed or failed.
                if try await apply(snapshot, self.base, self.waiting > 0) == .landed {
                    self.base = .known(snapshot)
                }
            } catch {
                Logger.library.error("\(self.label, privacy: .public) save failed reason=\(String(describing: error), privacy: .public) base kept")
            }
        }
    }

    /// Waits for every handed-over write (tests, the app's two ends).
    func awaitPendingWrites() async {
        await pendingWrite?.value
    }
}
