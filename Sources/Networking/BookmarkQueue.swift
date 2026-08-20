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

    enum Operation: Codable, Equatable {
        case create(itemId: String, time: Double, title: String)
        case delete(itemId: String, time: Double)

        var itemId: String {
            switch self {
            case .create(let id, _, _), .delete(let id, _): return id
            }
        }
    }

    private let opsKey = AppStorageKeys.pendingBookmarkOps
    private let cachePrefix = "bookmarkCache."

    private init() {}

    // MARK: - Pending-Ops

    func enqueue(_ op: Operation) {
        var ops = pendingOps()
        // A bookmark created offline and deleted again offline cancels out —
        // drop both ops instead of sending them.
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

    /// 6a411cf: unread is not empty — these are bookmarks the user made and
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
        UserDefaults.standard.set(try? JSONEncoder().encode(ops), forKey: opsKey)
        readFailed = false
    }

    private var flushInFlight = false

    /// Sends pending ops in original order. If one fails, it and all FOLLOWING
    /// ops of the same book stay queued (per-book order is preserved); ops of
    /// other books are still attempted.
    func flush(provider: any AudioProvider) async {
        guard !flushInFlight else { return }
        flushInFlight = true
        defer { flushInFlight = false }

        let ops = pendingOps()
        guard !ops.isEmpty else { return }
        var failedItemIds: Set<String> = []
        var remaining: [Operation] = []

        for op in ops {
            guard !failedItemIds.contains(op.itemId) else {
                remaining.append(op)
                continue
            }
            do {
                switch op {
                case .create(let itemId, let time, let title):
                    try await provider.createBookmark(itemId: itemId, time: time, title: title)
                case .delete(let itemId, let time):
                    try await provider.deleteBookmark(itemId: itemId, time: time)
                }
            } catch {
                failedItemIds.insert(op.itemId)
                remaining.append(op)
            }
        }
        save(remaining)
    }

    // MARK: - Offline cache of the server list

    func cache(_ bookmarks: [ABSBookmark], forItemId itemId: String) {
        UserDefaults.standard.set(
            try? JSONEncoder().encode(bookmarks),
            forKey: cachePrefix + itemId
        )
    }

    func cachedBookmarks(forItemId itemId: String) -> [ABSBookmark] {
        guard let data = UserDefaults.standard.data(forKey: cachePrefix + itemId),
              let bookmarks = try? JSONDecoder().decode([ABSBookmark].self, from: data) else { return [] }
        return bookmarks
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
