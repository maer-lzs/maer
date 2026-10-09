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
    enum Outcome: Equatable {
        /// The rows hold the snapshot now; the base becomes it.
        case landed
        /// Nothing was written on purpose (no change).
        case skipped
        /// An empty snapshot over rows was refused, and how it spoke.
        case refused(WipeRefusal)
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
    /// Whether the start missed rows: it failed as a whole, or rows were
    /// there that did not decode. A landed write does not clear it, unlike
    /// `base`: the rows it could not read are still in the table. Only a
    /// later read that sees every row does. A question that needs every
    /// row known asks this, not `startReadFailed`.
    private(set) var startIncomplete = false

    /// Rows came back to the table that this build does not read (a
    /// hand-over brought an account's rows back as they were): the rows
    /// hold more than the memory, as after a start that missed some.
    func noteRowsNotRead() {
        startIncomplete = true
    }

    /// The store's adoption of rows read after a failed start: it takes the
    /// rows into its memory by its rule. A chain without it holds every
    /// write over unread rows.
    var adopt: (@MainActor (Snapshot) -> Void)?
    /// The last handed-over write.
    private var pendingWrite: Task<Void, Never>?
    /// Writes handed over and not yet begun. It drops as a write begins, so
    /// `laterQueued` sees only the writes queued by then: a write queued
    /// while this one awaits its read or its apply goes uncounted, and a
    /// refused wipe can still be told although a later write takes the
    /// memory anyway. A false alarm made smaller, not closed.
    private var waiting = 0
    /// The number the next handed-over write gets.
    private var issued = 0
    /// Writes handed over and not yet ended (waiting or running).
    private var unfinished = 0
    /// Whether a write is on its way to the rows: a read of the rows beside
    /// the chain would see them before it landed.
    private var isWriting: Bool { unfinished > 0 }

    /// THE rule for reading the rows beside the chain (the rows a build
    /// does not decode, read raw for a hand-over): never beside a write. A
    /// reader that reads at once asks this and holds while it is false.
    var mayReadBesideTheChain: Bool { !isWriting }

    /// The same rule for a reader that reads off the main actor: it waits
    /// the chain out, reads, and gets nil when a write was handed over
    /// while it read, because the rows it saw may be gone or changed; the
    /// caller reads again at its next question.
    func readAfterTheChain<Value>(_ read: () async -> Value) async -> Value? {
        await awaitPendingWrites()
        let before = issued
        let value = await read()
        guard issued == before, !isWriting else { return nil }
        return value
    }
    /// The last write a narrowed permission covers: a permission to empty
    /// narrowed at its call covers the writes queued by then and its own,
    /// never a write queued later. It only grows, as the numbers do.
    private var narrowedThrough: Int?
    /// How the last refused wipe spoke (a witness reads it).
    private(set) var lastRefusal: WipeRefusal?

    init(label: String) {
        self.label = label
        RowKeepers.register(owner: self) { [weak self] in await self?.awaitPendingWrites() }
    }

    /// The outcome of the store's start read: the rows it read and how many
    /// did not decode, or a read that failed as a whole.
    func started(rows: Snapshot?, skipped: Int) {
        base = RowBase.afterLoad(rows: rows, skipped: skipped)
        startReadFailed = false
        startIncomplete = skipped > 0
        logSkippedStart(skipped, rowsSeen: rows != nil)
    }

    /// The one line of a start with rows that did not decode. The table's
    /// read names the table; this line names the owner and what follows:
    /// the base is unknown, no write removes an unread row.
    private func logSkippedStart(_ skipped: Int, rowsSeen: Bool) {
        guard skipped > 0 else { return }
        Logger.library.error("\(self.label, privacy: .public) start: skipped=\(skipped) rows=\(rowsSeen ? "some" : "none", privacy: .public) base=unknown")
    }

    /// The start read failed as a whole: nothing read, the mark set.
    func startReadFailedAsAWhole(reason: String) {
        base = .unknown(seen: nil)
        startReadFailed = true
        startIncomplete = true
        Logger.library.error("\(self.label, privacy: .public) rows read failed reason=\(reason, privacy: .public) base=unknown")
    }

    /// A start read whose base the store reckons itself (a read in stages
    /// that saw part of the rows before it failed: unknown with what it
    /// saw); the mark stays off, the store holds what it saw. `skipped` rows
    /// that did not decode speak in the same line as `started(rows:skipped:)`;
    /// a read that failed after the first stage says its own line.
    func started(base: RowBase<Snapshot>, skipped: Int) {
        self.base = base
        startReadFailed = false
        if case .unknown(let seen) = base {
            startIncomplete = true
            logSkippedStart(skipped, rowsSeen: seen != nil)
        } else {
            startIncomplete = false
        }
    }

    /// Hands one write to the chain. `narrowing` says that this call's
    /// permission to empty was narrowed at the call (`RowEmptying.atCall`).
    /// `read` reads the rows again (the rows, nil when there are none, and
    /// how many did not decode); `take` gives the store's memory, nil once
    /// the store is gone; `apply` writes the snapshot against the base and
    /// says whether it landed, and gets how a refused wipe of this write
    /// speaks (`WipeRefusal`: a later write already queued takes the memory
    /// anyway; a permission narrowed for this write; otherwise a suspicion).
    func write(narrowing: Bool = false,
               read: @escaping @MainActor () async throws -> (rows: Snapshot?, skipped: Int),
               take: @escaping @MainActor () -> Snapshot?,
               apply: @escaping @MainActor (_ snapshot: Snapshot, _ base: RowBase<Snapshot>,
                                            _ refusal: WipeRefusal) async throws -> Outcome) {
        let previous = pendingWrite
        let number = issued
        issued += 1
        if narrowing { narrowedThrough = number }
        waiting += 1
        unfinished += 1
        pendingWrite = Task(priority: .utility) { [weak self] in
            await previous?.value
            guard let self else { return }
            defer { self.unfinished -= 1 }
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
                    self.startIncomplete = load.skipped > 0
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
                let narrowed = self.narrowedThrough.map { number <= $0 } ?? false
                let refusal = WipeRefusal.of(laterQueued: self.waiting > 0, narrowedPermission: narrowed)
                switch try await apply(snapshot, self.base, refusal) {
                case .landed: self.base = .known(snapshot)
                case .refused(let spoke): self.lastRefusal = spoke
                case .skipped: break
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
