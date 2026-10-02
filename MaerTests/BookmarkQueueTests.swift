// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Foundation
import Testing
@testable import Maer

/// Tests für die Offline-Lesezeichen-Queue: Aufheben von Create+Delete,
/// optimistische Sicht (Cache + Pending) und Reihenfolge-Erhalt.
/// Reine Logik ohne Netz. Flush() wird hier bewusst nicht getestet.
@MainActor
struct BookmarkQueueTests {
    private let itemId = "bookmark-test-item"

    /// Queue nutzt UserDefaults. Vor jedem Test sauber räumen.
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

    // MARK: - The flush and what arrives while it waits

    /// A source whose create waits a turn and then runs a hook: the queue
    /// changes while a flush waits on the network, as it does when the
    /// person adds or removes a bookmark during a slow flush.
    private final class HookProvider: AudioProvider {
        var providerId: String { "bookmark-hook" }
        var capabilities: ProviderCapabilities { [] }
        var streamAuthHeaders: [String: String] { [:] }
        var onCreate: ((Double) -> Void)?
        var created: [Double] = []
        func fetchLibraries() async throws -> [ABSLibrary] { [] }
        func fetchLibraryItems(libraryId: String) async throws -> [LibraryItem] { [] }
        func fetchItemDetail(itemId: String) async throws -> LibraryItemDetail {
            throw NSError(domain: "bookmark-hook", code: 404)
        }
        func coverURL(forItemId itemId: String) -> URL? { nil }
        func streamURL(forContentPath contentPath: String) -> URL? { nil }
        func fetchAllProgress() async throws -> [String: BookProgress] { [:] }
        func updateProgress(itemId: String, currentTime: Double, duration: Double, isFinished: Bool) async throws {}
        func fetchBookmarks(itemId: String) async throws -> [ABSBookmark] { [] }
        func createBookmark(itemId: String, time: Double, title: String) async throws {
            await Task.yield()
            let hook = onCreate
            onCreate = nil
            hook?(time)
            created.append(time)
        }
        func deleteBookmark(itemId: String, time: Double) async throws {}
    }

    @Test("die Regel nach dem Senden: geht nur, was ankam; Neues bleibt; ein gesendetes, inzwischen aufgehobenes Anlegen wird zum Loeschen")
    func theRuleAfterAFlush() {
        let a = BookmarkQueue.Operation.create(itemId: itemId, time: 10, title: "A")
        let b = BookmarkQueue.Operation.create(itemId: itemId, time: 20, title: "B")
        let failed = BookmarkQueue.Operation.create(itemId: "other", time: 5, title: "C")
        #expect(BookmarkQueue.afterFlush(current: [failed, a, b], sent: [a]) == [failed, b])
        #expect(BookmarkQueue.afterFlush(current: [], sent: [a]) == [.delete(itemId: itemId, time: 10)],
                "the server holds a bookmark the person removed meanwhile")
        let gone = BookmarkQueue.Operation.delete(itemId: itemId, time: 30)
        #expect(BookmarkQueue.afterFlush(current: [gone], sent: [gone]).isEmpty)
    }

    @Test("ein Lesezeichen, das waehrend des Sendens angelegt wird, ueberlebt den Flush")
    func aBookmarkQueuedDuringAFlushSurvives() async {
        reset()
        defer { reset() }
        BookmarkQueue.shared.enqueue(.create(itemId: itemId, time: 10, title: "first"))
        let provider = HookProvider()
        let id = itemId
        provider.onCreate = { _ in
            BookmarkQueue.shared.enqueue(.create(itemId: id, time: 20, title: "during"))
        }
        await BookmarkQueue.shared.flush(provider: provider)
        #expect(provider.created == [10], "the precondition: the first one was sent while the second arrived")
        #expect(BookmarkQueue.shared.pendingOps() == [.create(itemId: itemId, time: 20, title: "during")])
    }

    @Test("ein Loeschen waehrend des Sendens desselben Anlegens erreicht den Server als Loeschen")
    func aDeleteDuringTheSendBecomesADelete() async {
        reset()
        defer { reset() }
        BookmarkQueue.shared.enqueue(.create(itemId: itemId, time: 10, title: "first"))
        let provider = HookProvider()
        let id = itemId
        provider.onCreate = { time in
            BookmarkQueue.shared.enqueue(.delete(itemId: id, time: time))
        }
        await BookmarkQueue.shared.flush(provider: provider)
        #expect(provider.created == [10])
        #expect(BookmarkQueue.shared.pendingOps() == [.delete(itemId: itemId, time: 10)])
    }
}
#endif
