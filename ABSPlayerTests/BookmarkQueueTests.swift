// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later

#if canImport(Testing)
import Foundation
import Testing
@testable import ABSPlayer

/// Tests für die Offline-Lesezeichen-Queue: Aufheben von Create+Delete,
/// optimistische Sicht (Cache + Pending) und Reihenfolge-Erhalt.
/// Reine Logik ohne Netz — flush() wird hier bewusst nicht getestet.
@MainActor
struct BookmarkQueueTests {
    private let itemId = "bookmark-test-item"

    /// Queue nutzt UserDefaults — vor jedem Test sauber räumen.
    private func reset() {
        UserDefaults.standard.removeObject(forKey: AppStorageKeys.pendingBookmarkOps)
        BookmarkQueue.shared.cache([], forItemId: itemId)
    }

    @Test("Offline angelegt + offline gelöscht hebt sich auf")
    func createThenDeleteCancelsOut() {
        reset()
        BookmarkQueue.shared.enqueue(.create(itemId: itemId, time: 42.4, title: "Test"))
        BookmarkQueue.shared.enqueue(.delete(itemId: itemId, time: 42.9))
        #expect(BookmarkQueue.shared.pendingOps().isEmpty)
    }

    @Test("Pending-Create erscheint optimistisch in der effektiven Liste")
    func effectiveMergesPendingCreate() {
        reset()
        BookmarkQueue.shared.cache(
            [ABSBookmark(libraryItemId: itemId, title: "Server", time: 10, createdAt: nil)],
            forItemId: itemId
        )
        BookmarkQueue.shared.enqueue(.create(itemId: itemId, time: 20, title: "Offline"))
        let effective = BookmarkQueue.shared.effectiveBookmarks(forItemId: itemId)
        #expect(effective.map(\.title) == ["Server", "Offline"])
        reset()
    }

    @Test("Pending-Delete filtert den gecachten Server-Eintrag heraus")
    func effectiveFiltersPendingDelete() {
        reset()
        BookmarkQueue.shared.cache(
            [ABSBookmark(libraryItemId: itemId, title: "Server", time: 10, createdAt: nil)],
            forItemId: itemId
        )
        BookmarkQueue.shared.enqueue(.delete(itemId: itemId, time: 10))
        #expect(BookmarkQueue.shared.effectiveBookmarks(forItemId: itemId).isEmpty)
        // Der Delete bleibt als Op liegen (kein passendes Pending-Create).
        #expect(BookmarkQueue.shared.pendingOps().count == 1)
        reset()
    }

    @Test("Reihenfolge der Ops bleibt erhalten")
    func preservesOrder() {
        reset()
        BookmarkQueue.shared.enqueue(.create(itemId: itemId, time: 1, title: "A"))
        BookmarkQueue.shared.enqueue(.create(itemId: itemId, time: 2, title: "B"))
        let ops = BookmarkQueue.shared.pendingOps()
        #expect(ops.count == 2)
        if case .create(_, let t, _) = ops[0] { #expect(t == 1) }
        if case .create(_, let t, _) = ops[1] { #expect(t == 2) }
        reset()
    }
}
#endif
