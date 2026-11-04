// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation
import OSLog
import Synchronization

/// Where the register of `ItemOwners` lies: a file of its own beside the
/// app's database, like `RestingShelf`, not in the defaults. It grows with
/// the library and is written after full loads, and the defaults are one
/// file read whole at every start and written whole at every change. Like
/// the resting shelf it stays in the device backup. No carrier reads it.
nonisolated struct ItemOwnerShelf: Sendable {
    let file: URL

    /// Counts the registers written in this process: a reader that keeps
    /// what it worked out from the register asks this, not the file.
    private static let writes = Mutex<Int>(0)

    /// The number of registers written so far; a new number is a new stand.
    static var generation: Int { writes.withLock { $0 } }

    /// The app's register, beside the app's database file.
    static var app: ItemOwnerShelf? {
        MaerDatabase.url.map { ItemOwnerShelf(file: $0.deletingLastPathComponent().appendingPathComponent("item-owners.json")) }
    }

    /// The register as it stands. A file that is there and cannot be read
    /// answers `.corrupt`: no owner is known then, so nothing is cleaned by
    /// it, and it is never replaced by an empty register.
    func read() -> CorruptStore.Outcome<ItemOwners> {
        CorruptStore.load(ItemOwners.self, from: file, label: "ITEM owners")
    }

    /// Writes `owners`; a failure leaves the file as it was and says so.
    /// An empty register after an unreadable read is not written.
    func write(_ owners: ItemOwners, afterCorruptRead: Bool) {
        guard CorruptStore.maySave(isEmpty: owners.owners.isEmpty, afterCorruptRead: afterCorruptRead) else {
            Logger.library.error("ITEM owners not written: empty over an unreadable register")
            return
        }
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(owners).write(to: file, options: .atomic)
            Self.writes.withLock { $0 += 1 }
        } catch {
            Logger.library.error("ITEM owners write failed: \(FailureReason.of(error), privacy: .public)")
        }
    }
}
