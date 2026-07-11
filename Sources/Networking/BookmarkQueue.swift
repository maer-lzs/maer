import Foundation

/// Offline-Fähigkeit für Lesezeichen: Anlegen/Löschen, das den Server nicht
/// erreicht, wird hier persistiert und nachgereicht (analog `SyncQueue`).
/// Zusätzlich wird pro Buch die zuletzt vom Server geladene Liste gecacht,
/// damit das Lesezeichen-Sheet auch offline etwas zeigen kann.
///
/// Ops behalten ihre REIHENFOLGE (Array, kein Dictionary): ein Löschen nach
/// einem Anlegen derselben Position muss auch so beim Server ankommen.
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
        // Ein offline angelegtes Lesezeichen, das offline wieder gelöscht
        // wird, hebt sich auf — beide Ops verwerfen statt sie zu senden.
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

    func pendingOps() -> [Operation] {
        guard let data = UserDefaults.standard.data(forKey: opsKey),
              let ops = try? JSONDecoder().decode([Operation].self, from: data) else { return [] }
        return ops
    }

    private func save(_ ops: [Operation]) {
        UserDefaults.standard.set(try? JSONEncoder().encode(ops), forKey: opsKey)
    }

    private var flushInFlight = false

    /// Sendet wartende Ops in Original-Reihenfolge. Schlägt eine fehl, bleibt
    /// sie samt allen NACHFOLGENDEN Ops desselben Buchs liegen (Reihenfolge
    /// pro Buch bleibt gewahrt); Ops anderer Bücher werden weiter versucht.
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

    // MARK: - Offline-Cache der Server-Liste

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

    /// Cache + Pending-Ops zusammengerechnet: das, was der Nutzer offline als
    /// aktuellen Stand sehen soll (optimistisch).
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
