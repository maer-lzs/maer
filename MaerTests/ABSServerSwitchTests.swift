// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// A switch of the Audiobookshelf server loses no stand heard offline: the
/// first full load of the new server cleans nothing of the old one, and a
/// stand queued under the old server waits for it instead of being sent to
/// the new one and dropped on its absence answer.
@MainActor
@Suite(.serialized)
struct ABSServerSwitchTests {
    /// One server with one book library; refuses a title it does not hold
    /// with 404, as Audiobookshelf answers it.
    final class Server: AudioProvider {
        let books: [Maer.LibraryItem]
        let progress: [String: BookProgress]
        var sent: [String: Double] = [:]
        init(books: [String], progress: [String: BookProgress] = [:]) {
            self.books = books.map(Self.book)
            self.progress = progress
        }
        static func book(_ id: String) -> Maer.LibraryItem {
            Maer.LibraryItem(id: id, media: LibraryItemMedia(
                metadata: LibraryItemMetadata(title: id, authorName: nil, narratorName: nil,
                                              seriesName: nil, genres: nil, publishedYear: nil, description: nil),
                duration: 1000, chapters: nil, tracks: nil), addedAt: nil)
        }
        var providerId: String { "abs-switch" }
        var keepsMarksOnDevice: Bool { false }
        var capabilities: ProviderCapabilities { [.progressSync] }
        var streamAuthHeaders: [String: String] { [:] }
        func fetchLibraries() async throws -> [ABSLibrary] { [ABSLibrary(id: "books", name: "Books", mediaType: "book")] }
        func fetchLibraryItems(libraryId: String) async throws -> [Maer.LibraryItem] { books }
        func fetchItemDetail(itemId: String) async throws -> LibraryItemDetail { throw NSError(domain: "abs-switch", code: 404) }
        func coverURL(forItemId itemId: String) -> URL? { nil }
        func streamURL(forContentPath contentPath: String) -> URL? { nil }
        func fetchAllProgress() async throws -> [String: BookProgress] { progress }
        func updateProgress(itemId: String, currentTime: Double, duration: Double, isFinished: Bool) async throws {
            guard books.contains(where: { $0.id == itemId }) else { throw APIError.http(404, "Not Found") }
            sent[itemId] = currentTime
        }
        func fetchBookmarks(itemId: String) async throws -> [ABSBookmark] { [] }
        func createBookmark(itemId: String, time: Double, title: String) async throws {}
        func deleteBookmark(itemId: String, time: Double) async throws {}
    }

    /// The three remembered values and the chosen library, put back after
    /// a case: they live in the app's own settings.
    private struct Saved {
        let values: [String: Any?]
        static let keys = [AppStorageKeys.absSignedInServer, AppStorageKeys.absLastFullLoadServer,
                           AppStorageKeys.absServerSwitchedAt, AppStorageKeys.absMoreThanOneServer,
                           AppStorageKeys.selectedLibraryId]
        init() { values = Dictionary(uniqueKeysWithValues: Self.keys.map { ($0, AppStorageKeys.object($0)) }) }
        func restore() { for (key, value) in values { AppStorageKeys.set(value, for: key) } }
    }

    private func queue() throws -> (SyncQueue, URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("abs-switch-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let database = MaerDatabase(path: directory.appendingPathComponent("maer.sqlite").path)
        return (SyncQueue(storage: SyncQueueRowStorage(database: database)), directory)
    }

    @Test("die Regel: geraeumt wird nur nach der vollen Ladung desselben Servers, ein fremder Stand wartet")
    func theRule() {
        #expect(ABSServerScope.cleanup(lastFullLoad: "https://a", current: "https://a", moreThanOneServer: false) == .clean)
        #expect(ABSServerScope.cleanup(lastFullLoad: "https://a", current: "https://a", moreThanOneServer: true) != .clean,
                "a device that knew two servers cleans no library id")
        #expect(ABSServerScope.cleanup(lastFullLoad: "https://a", current: "https://b", moreThanOneServer: false) != .clean)
        #expect(ABSServerScope.cleanup(lastFullLoad: nil, current: "https://b", moreThanOneServer: false) != .clean,
                "the first load after the update")
        #expect(ABSServerScope.cleanup(lastFullLoad: "https://a", current: nil, moreThanOneServer: false) != .clean)
        let fate = { (id: String, server: String?, queued: Double?, switched: Double?) in
            ABSServerScope.queueFate(itemId: id, entryServer: server, queuedAt: queued, current: "https://b", switchedAt: switched)
        }
        #expect(fate("book", "https://b", 10, 5) == .send)
        #expect(fate("book", "https://a", 10, 5) == .wait)
        #expect(fate("book", nil, 1, 5) == .sendKeptOnAbsence, "an older entry from before the switch")
        #expect(fate("book", nil, 10, 5) == .send)
        #expect(fate("book", nil, 10, nil) == .send)
        #expect(fate("sub:song:1", "https://a", 10, 5) == .send, "an id with a namespace names its source itself")
        #expect(ABSServerScope.server(of: "book", signedIn: "https://a") == "https://a")
        #expect(ABSServerScope.server(of: "jf:book:1", signedIn: "https://a") == nil)
    }

    @Test("ein Eintrag der Warteschlange aus der Zeit vor dem Server liest sich ohne Server")
    func anOlderEntryReadsWithoutAServer() throws {
        let old = Data(#"{"currentTime":321,"duration":1000,"isFinished":false,"queuedAt":5}"#.utf8)
        let entry = try JSONDecoder().decode(SyncQueue.PendingUpdate.self, from: old)
        #expect(entry.server == nil && entry.currentTime == 321 && entry.queuedAt == 5)
    }

    @Test("Wechsel von A zu B und zurueck: der offline gehoerte Stand von A bleibt und geht an A, nie an B")
    func aSwitchKeepsTheUnsentStand() async throws {
        let saved = Saved()
        defer { saved.restore() }
        let (queue, directory) = try queue()
        defer { try? FileManager.default.removeItem(at: directory) }
        let bookA = "switch-a-\(UUID().uuidString)"
        let bookB = "switch-b-\(UUID().uuidString)"
        defer { ListeningStore.forgetBackups(where: { $0 == bookA }) }
        let now = Date().timeIntervalSince1970 * 1000

        // Signed in at A, A fully loaded once; offline heard to 321 s, sent 100 s.
        AppStorageKeys.noteABSSignIn("https://a.example", nowMs: now - 120_000)
        AppStorageKeys.set("https://a.example", for: AppStorageKeys.absLastFullLoadServer)
        ListeningStore.noteFlushed(bookA, position: 100, atMs: now - 60_000)
        ListeningStore.store(bookA, entry: [321, now])
        await queue.enqueue(itemId: bookA, currentTime: 321, duration: 1000, isFinished: false)
        #expect(queue.pendingUpdate(itemId: bookA)?.server == "https://a.example", "the stand carries its server")

        // The switch, and B's first full load.
        AppStorageKeys.noteABSSignIn("https://b.example", nowMs: now + 1)
        AppStorageKeys.set(nil, for: AppStorageKeys.selectedLibraryId)
        let serverB = Server(books: [bookB])
        await LibraryViewModel(provider: serverB).loadLibrary()
        try await Task.sleep(for: .milliseconds(500))
        #expect(ListeningStore.backup(bookA)?.first == 321, "B's first load cleaned A's stand")

        // The queue sends while B is signed in.
        await queue.flush { _ in ProgressTarget(key: "abs", client: serverB) }
        #expect(serverB.sent[bookA] == nil, "A's stand went to B")
        #expect(queue.pendingUpdate(itemId: bookA)?.currentTime == 321, "A's stand left the queue under B")

        // Back to A: the stand goes there.
        AppStorageKeys.noteABSSignIn("https://a.example", nowMs: now + 2)
        let serverA = Server(books: [bookA], progress: [bookA: BookProgress(fraction: 0.1, isFinished: false,
                                                                            lastUpdate: now - 60_000, currentTime: 100)])
        await queue.flush { _ in ProgressTarget(key: "abs", client: serverA) }
        #expect(serverA.sent[bookA] == 321, "the unsent stand did not reach its server")
        #expect(!queue.hasPendingUpdate(itemId: bookA))
    }

    @Test("derselbe Server raeumt weiter, der erste Start ohne gemerkten Server raeumt einmal nicht")
    func theSameServerStillCleans() async throws {
        let saved = Saved()
        defer { saved.restore() }
        let gone = "switch-gone-\(UUID().uuidString)"
        let kept = "switch-kept-\(UUID().uuidString)"
        defer { ListeningStore.forgetBackups(where: { $0 == gone }) }
        let now = Date().timeIntervalSince1970 * 1000
        AppStorageKeys.set(nil, for: AppStorageKeys.selectedLibraryId)
        // A device that only ever knew this one server.
        AppStorageKeys.set(nil, for: AppStorageKeys.absSignedInServer)
        AppStorageKeys.set(nil, for: AppStorageKeys.absMoreThanOneServer)
        AppStorageKeys.noteABSSignIn("https://a.example", nowMs: now)
        #expect(!AppStorageKeys.bool(AppStorageKeys.absMoreThanOneServer, default: false), "the precondition: one server")

        // No full load remembered: this once nothing goes, the server is noted.
        AppStorageKeys.set(nil, for: AppStorageKeys.absLastFullLoadServer)
        ListeningStore.store(gone, entry: [50, now])
        await LibraryViewModel(provider: Server(books: [kept])).loadLibrary()
        try await Task.sleep(for: .milliseconds(500))
        #expect(ListeningStore.backup(gone)?.first == 50, "the first load after the update cleaned")
        #expect(AppStorageKeys.string(AppStorageKeys.absLastFullLoadServer) == "https://a.example")

        // The next full load of the same server cleans a book that left.
        await LibraryViewModel(provider: Server(books: [kept])).loadLibrary()
        try await Task.sleep(for: .milliseconds(500))
        #expect(ListeningStore.backup(gone) == nil, "the same server no longer cleans a book that left")
    }

    @Test("nach einem Wechsel raeumt auch die zweite volle Ladung von B nichts von A")
    func aSecondLoadOfTheNewServerKeepsTheOld() async throws {
        let saved = Saved()
        defer { saved.restore() }
        let bookA = "switch-two-a-\(UUID().uuidString)"
        let bookB = "switch-two-b-\(UUID().uuidString)"
        let d = UserDefaults.standard
        defer {
            ListeningStore.forgetBackups(where: { $0 == bookA })
            d.removeObject(forKey: AppStorageKeys.playbackRate(bookA))
            d.removeObject(forKey: PlayedTail.key(bookA))
        }
        let now = Date().timeIntervalSince1970 * 1000
        AppStorageKeys.set(nil, for: AppStorageKeys.absSignedInServer)
        AppStorageKeys.set(nil, for: AppStorageKeys.absMoreThanOneServer)
        AppStorageKeys.noteABSSignIn("https://a.example", nowMs: now - 120_000)
        AppStorageKeys.set("https://a.example", for: AppStorageKeys.absLastFullLoadServer)
        ListeningStore.store(bookA, entry: [321, now])
        d.set(1.5, forKey: AppStorageKeys.playbackRate(bookA))
        d.set([1.0], forKey: PlayedTail.key(bookA))

        AppStorageKeys.noteABSSignIn("https://b.example", nowMs: now)
        #expect(AppStorageKeys.bool(AppStorageKeys.absMoreThanOneServer, default: false), "the device knew two servers")
        AppStorageKeys.set(nil, for: AppStorageKeys.selectedLibraryId)
        for _ in 0..<2 {
            await LibraryViewModel(provider: Server(books: [bookB])).loadLibrary()
            try await Task.sleep(for: .milliseconds(500))
        }
        #expect(ListeningStore.backup(bookA)?.first == 321, "a load of B cleaned A's stand")
        #expect(d.object(forKey: AppStorageKeys.playbackRate(bookA)) as? Double == 1.5, "a load of B cleaned A's speed")
        #expect(d.object(forKey: PlayedTail.key(bookA)) != nil, "a load of B cleaned A's played tail")
    }

    @Test("ein Eintrag von vor dem Wechsel ohne Server geht an den neuen Server, dessen 404 verwirft ihn nicht")
    func anOlderEntryIsKeptOnAbsenceAfterASwitch() async throws {
        let saved = Saved()
        defer { saved.restore() }
        let (queue, directory) = try queue()
        defer { try? FileManager.default.removeItem(at: directory) }
        let book = "switch-old-\(UUID().uuidString)"
        let now = Date().timeIntervalSince1970 * 1000
        // An entry from before the rule: no server signed in, none stamped.
        AppStorageKeys.set(nil, for: AppStorageKeys.absSignedInServer)
        await queue.enqueue(itemId: book, currentTime: 77, duration: 1000, isFinished: false)
        #expect(queue.pendingUpdate(itemId: book)?.server == nil, "the precondition: an entry without a server")
        AppStorageKeys.noteABSSignIn("https://b.example", nowMs: now + 60_000)
        let serverB = Server(books: [])
        await queue.flush { _ in ProgressTarget(key: "abs", client: serverB) }
        #expect(queue.pendingUpdate(itemId: book)?.currentTime == 77, "the absence answer after a switch dropped the stand")
    }
}
#endif
