// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation
import OSLog

/// Offline support for bookmarks: create/delete that does not reach the server
/// is persisted here and retried later (like `SyncQueue`). Additionally, the
/// list last loaded from the server is cached per book so the bookmark sheet
/// can show something offline too.
///
/// Ops keep their ORDER (array, not dictionary): a delete after a create of the
/// same position must reach the server in that order.
@MainActor
final class BookmarkQueue {
    static let shared = BookmarkQueue()

    nonisolated enum Operation: Codable, Equatable, Sendable {
        case create(itemId: String, time: Double, title: String)
        case delete(itemId: String, time: Double)

        var itemId: String {
            switch self {
            case .create(let id, _, _), .delete(let id, _): return id
            }
        }
    }

    private let opsKey = AppStorageKeys.pendingBookmarkOps
    /// The offline copy of the server's list, one entry per title in rows;
    /// it leaves with its book (`AppStorageKeys.cleanupPerBookRows`).
    private var cacheRows: BookmarkCacheRows { BookmarkCacheRows.matching(AppStorageKeys.store) }

    private init() {}

    // MARK: - Pending-Ops

    func enqueue(_ op: Operation) {
        var ops = pendingOps()
        // A bookmark created offline and deleted again offline cancels out.
        // Drop both ops instead of sending them.
        if case .delete(let itemId, let time) = op,
           let idx = ops.lastIndex(where: {
               if case .create(let cid, let ctime, _) = $0 { return cid == itemId && Int(ctime) == Int(time) }
               return false
           }) {
            ops.remove(at: idx)
            save(ops)
            return
        }
        ops.append(op)
        save(ops)
    }

    /// Unread is not empty. These are bookmarks the user made and
    /// the server has not seen yet.
    private var readFailed = false

    func pendingOps() -> [Operation] {
        let outcome = CorruptStore.load([Operation].self, defaultsKey: opsKey,
                                        label: "bookmark queue")
        readFailed = outcome.blocksEmptySave
        return outcome.value ?? []
    }

    private func save(_ ops: [Operation]) {
        guard CorruptStore.maySave(isEmpty: ops.isEmpty, afterCorruptRead: readFailed) else {
            Logger.library.error("bookmark queue NOT saved: the stored queue was unreadable and this state is empty")
            return
        }
        AppStorageKeys.set(try? JSONEncoder().encode(ops), for: opsKey)
        readFailed = false
    }

    private var flushInFlight = false

    /// Sends pending ops in original order. If one fails, it and all FOLLOWING
    /// ops of the same book stay queued (per-book order is preserved); ops of
    /// other books are still attempted. The queue is read again at the end:
    /// an op queued while the flush waited on the network stays, and only
    /// what reached the server leaves.
    func flush(provider: any AudioProvider) async {
        guard !flushInFlight else { return }
        flushInFlight = true
        defer { flushInFlight = false }

        let ops = pendingOps()
        guard !ops.isEmpty else { return }
        var failedItemIds: Set<String> = []
        var sent: [Operation] = []

        for op in ops {
            guard !failedItemIds.contains(op.itemId) else { continue }
            do {
                switch op {
                case .create(let itemId, let time, let title):
                    try await provider.createBookmark(itemId: itemId, time: time, title: title)
                case .delete(let itemId, let time):
                    try await provider.deleteBookmark(itemId: itemId, time: time)
                }
                sent.append(op)
            } catch {
                // It stays queued, and so does everything after it for
                // this book; the next flush tries again.
                Logger.library.notice("bookmark op stays queued: \(FailureReason.of(error), privacy: .public)")
                failedItemIds.insert(op.itemId)
            }
        }
        save(Self.afterFlush(current: pendingOps(), sent: sent))
    }

    /// The queue after a flush: what is stored now, less the ops that reached
    /// the server. An op queued while the flush waited stays. A create that
    /// reached the server but was cancelled meanwhile by a delete (the queue
    /// dropped both) left the server holding the bookmark, so its delete is
    /// queued in its place. Pure, so it needs no actor.
    nonisolated static func afterFlush(current: [Operation], sent: [Operation]) -> [Operation] {
        var out = current
        for op in sent {
            if let index = out.firstIndex(of: op) {
                out.remove(at: index)
            } else if case .create(let itemId, let time, _) = op {
                out.append(.delete(itemId: itemId, time: time))
            }
        }
        return out
    }

    // MARK: - Offline cache of the server list

    func cache(_ bookmarks: [ABSBookmark], forItemId itemId: String) {
        cacheRows.setEntry(CarrierRowsSpec.entryOwner, itemId, bookmarks)
    }

    func cachedBookmarks(forItemId itemId: String) -> [ABSBookmark] {
        cacheRows.entry(CarrierRowsSpec.entryOwner, itemId) ?? []
    }

    /// Cache + pending ops combined: what the user should see offline as the
    /// current state (optimistic).
    func effectiveBookmarks(forItemId itemId: String) -> [ABSBookmark] {
        var bookmarks = cachedBookmarks(forItemId: itemId)
        for op in pendingOps() where op.itemId == itemId {
            switch op {
            case .create(let id, let time, let title):
                bookmarks.append(ABSBookmark(libraryItemId: id, title: title, time: time, createdAt: nil))
            case .delete(_, let time):
                bookmarks.removeAll { Int($0.time) == Int(time) }
            }
        }
        return bookmarks.sorted { $0.time < $1.time }
    }
}
