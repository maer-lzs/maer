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
                           AppStorageKeys.selectedLibraryId, KnownServers.storeKey,
                           AppStorageKeys.absSpellingMarkReviewed]
        /// The register of owners is a file of its own beside the database.
        let owners: Data?
        init() {
            values = Dictionary(uniqueKeysWithValues: Self.keys.map { ($0, AppStorageKeys.object($0)) })
            owners = ItemOwnerShelf.app.flatMap { try? Data(contentsOf: $0.file) }
        }
        func restore() {
            for (key, value) in values { AppStorageKeys.set(value, for: key) }
            if let file = ItemOwnerShelf.app?.file {
                if let owners { try? owners.write(to: file, options: .atomic) } else { try? FileManager.default.removeItem(at: file) }
            }
        }
    }

    private static func owner(of itemId: String) -> String? { ItemOwnerShelf.app?.read().value?.owner(of: itemId) }

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
        #expect(ABSServerScope.cleanup(lastFullLoad: "https://a", current: "https://a", moreThanOneServer: true) == .cleanOwned,
                "a device that knew two servers cleans only the loaded server's own ids")
        #expect(ABSServerScope.cleanup(lastFullLoad: "https://a", current: "https://b", moreThanOneServer: true) == .cleanOwned)
        #expect(ABSServerScope.cleanup(lastFullLoad: "https://a", current: nil, moreThanOneServer: true) != .clean)
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

    /// One full load of `server` and the end of the key sweep it set off,
    /// not a clock; true when it set one off.
    @discardableResult
    private func load(_ server: Server) async -> Bool {
        let model = LibraryViewModel(provider: server)
        await model.loadLibrary()
        await model.keySweep?.value
        return model.keySweep != nil
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
        #expect(await !load(serverB), "B's first load set off a sweep of keys")
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
        #expect(await !load(Server(books: [kept])), "the first load after the update set off a sweep of keys")
        #expect(ListeningStore.backup(gone)?.first == 50, "the first load after the update cleaned")
        #expect(AppStorageKeys.string(AppStorageKeys.absLastFullLoadServer) == "https://a.example")

        // The next full load of the same server cleans a book that left.
        #expect(await load(Server(books: [kept])), "the same server set off no sweep of keys")
        #expect(ListeningStore.backup(gone) == nil, "the same server no longer cleans a book that left")
        // A device of one server cleans as before the register, also a book
        // the register never named; what stays is the server's own.
        #expect(Self.owner(of: gone) == nil)
        #expect(Self.owner(of: kept) == "https://a.example", "a full list did not name its books in the register")
    }

    @Test("zwei Server raeumen je ihre eigenen Buecher: das gegangene Buch von A geht mit der Ladung von A, die von B und der Altbestand bleiben")
    func twoServersCleanTheirOwn() async throws {
        let saved = Saved()
        defer { saved.restore() }
        let tag = UUID().uuidString
        let (a1, a2, b1, old, both) = ("own-a1-\(tag)", "own-a2-\(tag)", "own-b1-\(tag)", "own-old-\(tag)", "own-both-\(tag)")
        let books = [a1, a2, b1, old, both]
        let d = UserDefaults.standard
        defer { for book in books { d.removeObject(forKey: AppStorageKeys.playbackRate(book)) } }
        for book in books { d.set(1.5, forKey: AppStorageKeys.playbackRate(book)) }
        let rate = { (book: String) in d.object(forKey: AppStorageKeys.playbackRate(book)) as? Double }
        let now = Date().timeIntervalSince1970 * 1000
        for key in [AppStorageKeys.absSignedInServer, AppStorageKeys.absMoreThanOneServer,
                    AppStorageKeys.absLastFullLoadServer, AppStorageKeys.selectedLibraryId] { AppStorageKeys.set(nil, for: key) }

        AppStorageKeys.noteABSSignIn("https://a.example", nowMs: now)
        await load(Server(books: [a1, a2, both]))
        AppStorageKeys.noteABSSignIn("https://b.example", nowMs: now + 1)
        #expect(await !load(Server(books: [b1, both])), "B's load cleaned although none of B's books left")
        #expect(AppStorageKeys.bool(AppStorageKeys.absMoreThanOneServer, default: false), "the precondition: two servers")
        AppStorageKeys.noteABSSignIn("https://a.example", nowMs: now + 2)
        #expect(await load(Server(books: [a1, both])), "A's load did not clean the book that left A")

        #expect(rate(a2) == nil, "A's book that left stays")
        #expect(rate(a1) == 1.5)
        #expect(rate(b1) == 1.5, "A's load cleaned B's book")
        #expect(rate(old) == 1.5, "a book no full load named was cleaned")
        #expect(rate(both) == 1.5, "a book on both servers was cleaned")
        #expect(Self.owner(of: a2) == nil, "the register still names a cleaned book")
        #expect(Self.owner(of: b1) == "https://b.example")
        #expect(Self.owner(of: both) == "https://a.example", "the last full load to name a book owns it")
        #expect(Self.owner(of: old) == nil)
    }

    /// The ids that go are decided when a load ends, as a value: a second
    /// load that notes its ids while the first one's sweep runs changes
    /// nothing that sweep cleans.
    @Test("zwei volle Ladungen in einem Zug: A raeumt sein gegangenes Buch, ein Buch von B, das A nicht nennt, bleibt")
    func twoLoadsInOneGo() async throws {
        let saved = Saved()
        defer { saved.restore() }
        let tag = UUID().uuidString
        let (aKept, aLeft, shared, bLeft) = ("go-a-\(tag)", "go-a-left-\(tag)", "go-shared-\(tag)", "go-b-left-\(tag)")
        let books = [aKept, aLeft, shared, bLeft]
        let d = UserDefaults.standard
        defer { for book in books { d.removeObject(forKey: AppStorageKeys.playbackRate(book)) } }
        for book in books { d.set(1.5, forKey: AppStorageKeys.playbackRate(book)) }
        let rate = { (book: String) in d.object(forKey: AppStorageKeys.playbackRate(book)) as? Double }
        let now = Date().timeIntervalSince1970 * 1000
        for key in [AppStorageKeys.absSignedInServer, AppStorageKeys.absMoreThanOneServer,
                    AppStorageKeys.absLastFullLoadServer, AppStorageKeys.selectedLibraryId] { AppStorageKeys.set(nil, for: key) }
        AppStorageKeys.noteABSSignIn("https://a.example", nowMs: now)
        await load(Server(books: [aKept, aLeft]))
        AppStorageKeys.noteABSSignIn("https://b.example", nowMs: now + 1)
        await load(Server(books: [shared, bLeft]))

        // A, then B, the second before the first one's sweep ended.
        AppStorageKeys.noteABSSignIn("https://a.example", nowMs: now + 2)
        let first = LibraryViewModel(provider: Server(books: [aKept]))
        await first.loadLibrary()
        AppStorageKeys.noteABSSignIn("https://b.example", nowMs: now + 3)
        let second = LibraryViewModel(provider: Server(books: [shared]))
        await second.loadLibrary()
        #expect(first.keySweep != nil && second.keySweep != nil, "the precondition: both loads cleaned")
        await first.keySweep?.value
        await second.keySweep?.value

        #expect(rate(shared) == 1.5, "A's load cleaned a book of B that A does not name")
        #expect(rate(aKept) == 1.5)
        #expect(rate(aLeft) == nil, "A's book that left stays")
        #expect(rate(bLeft) == nil, "B's book that left stays")
        #expect(Self.owner(of: shared) == "https://b.example")
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
        for round in 1...2 {
            #expect(await !load(Server(books: [bookB])), "load \(round) of B set off a sweep of keys")
        }
        #expect(ListeningStore.backup(bookA)?.first == 321, "a load of B cleaned A's stand")
        #expect(d.object(forKey: AppStorageKeys.playbackRate(bookA)) as? Double == 1.5, "a load of B cleaned A's speed")
        #expect(d.object(forKey: PlayedTail.key(bookA)) != nil, "a load of B cleaned A's played tail")
    }

    @Test("ein Server hat einen Namen: ohne Zugangswerte, Wirt klein, ohne Standard-Port und Schraegstrich")
    func aServerHasOneName() {
        let name = "https://abs.example.com"
        #expect(ABSServerScope.identity(of: "https://Name:Secret@ABS.Example.com:443/") == name)
        #expect(ABSServerScope.identity(of: "HTTPS://abs.example.com/?token=abc#x") == name)
        #expect(ABSServerScope.identity(of: "http://abs.example.com:80") == "http://abs.example.com")
        #expect(ABSServerScope.identity(of: "https://abs.example.com:13378/sub/") == "https://abs.example.com:13378/sub",
                "another port and a path are part of the server")
        #expect(ABSServerScope.identity(of: "https://other.example.com") != name)
    }

    @Test("die Anmeldung merkt den Namen ohne Zugangswerte, eine andere Schreibweise ist derselbe Server")
    func theSignInKeepsNoSecret() {
        let saved = Saved()
        defer { saved.restore() }
        AppStorageKeys.set(nil, for: AppStorageKeys.absSignedInServer)
        AppStorageKeys.set(nil, for: AppStorageKeys.absMoreThanOneServer)
        AppStorageKeys.noteABSSignIn("https://Name:Secret@ABS.Example.com/", nowMs: 1)
        let stored = AppStorageKeys.string(AppStorageKeys.absSignedInServer)
        #expect(stored == "https://abs.example.com", "the settings hold \(stored ?? "nothing")")
        #expect(stored?.contains("Secret") == false)
        AppStorageKeys.noteABSSignIn("https://abs.example.com:443", nowMs: 2)
        #expect(!AppStorageKeys.bool(AppStorageKeys.absMoreThanOneServer, default: false),
                "another spelling of the same server counted as a second one")
        #expect(AppStorageKeys.double(AppStorageKeys.absServerSwitchedAt) == 1, "another spelling counted as a switch")
        #expect(ABSServerScope.server(of: "book", signedIn: "https://Name:Secret@abs.example.com") == "https://abs.example.com",
                "a queued stand carries the name")
    }

    /// A queue whose entries the witness writes in their old form.
    private final class MemoryQueue: SyncQueueStorage {
        var entries: [String: SyncQueue.PendingUpdate] = [:]
        func load() -> [String: SyncQueue.PendingUpdate] { entries }
        func save(_ pending: [String: SyncQueue.PendingUpdate]) { entries = pending }
        func awaitPendingWrites() async {}
        let startReadFailed = false
    }

    @Test("gemerkte Server von vor dem Namen ziehen einmal um: Einstellungen und Warteschlange ohne Zugangswerte")
    func olderServersMoveToTheirName() async {
        let saved = Saved()
        defer { saved.restore() }
        AppStorageKeys.set("https://Name:Secret@ABS.Example.com/", for: AppStorageKeys.absSignedInServer)
        AppStorageKeys.set("https://abs.example.com:443", for: AppStorageKeys.absLastFullLoadServer)
        AppStorageKeys.normalizeABSServers()
        #expect(AppStorageKeys.string(AppStorageKeys.absSignedInServer) == "https://abs.example.com")
        #expect(AppStorageKeys.string(AppStorageKeys.absLastFullLoadServer) == "https://abs.example.com")

        let storage = MemoryQueue()
        storage.entries["book"] = SyncQueue.PendingUpdate(currentTime: 321, duration: 1000, isFinished: false,
                                                           queuedAt: 5, server: "https://Name:Secret@ABS.Example.com/")
        let queue = SyncQueue(storage: storage)
        #expect(await queue.normalizeServers() == 1)
        #expect(storage.entries["book"]?.server == "https://abs.example.com", "the queue keeps the secret")
        #expect(storage.entries["book"]?.currentTime == 321, "the stand itself moved")
        // The old raw value and the name are one server for the rule.
        #expect(ABSServerScope.queueFate(itemId: "book", entryServer: "https://Name:Secret@ABS.Example.com/",
                                         queuedAt: 5, current: "https://abs.example.com", switchedAt: 1) == .send)
        #expect(ABSServerScope.cleanup(lastFullLoad: "https://ABS.example.com:443/", current: "https://abs.example.com",
                                       moreThanOneServer: false) == .clean)
    }

    @Test("die Marke eines zweiten Servers, die eine andere Schreibweise setzte, faellt beim Umzug, wo das Register keinen zweiten zeigt")
    func aSpellingsMarkFallsWhereTheRegisterShowsOneServer() {
        let saved = Saved()
        defer { saved.restore() }
        func move(register: [String], signedIn: String?) -> Bool {
            // The first start of this build on a device 3.5.1 left.
            AppStorageKeys.set(nil, for: AppStorageKeys.absSpellingMarkReviewed)
            // Written as stored, without the register's notice to the cloud.
            let entries = register.map { KnownServer(url: $0, service: .audiobookshelf, lastSuccessAt: 1) }
                + [KnownServer(url: "https://music.example.com", service: .subsonic, lastSuccessAt: 1)]
            AppStorageKeys.set(try? JSONEncoder().encode(entries), for: KnownServers.storeKey)
            AppStorageKeys.set(signedIn, for: AppStorageKeys.absSignedInServer)
            AppStorageKeys.set(true, for: AppStorageKeys.absMoreThanOneServer)
            AppStorageKeys.set(7.0, for: AppStorageKeys.absServerSwitchedAt)
            AppStorageKeys.normalizeABSServers()
            #expect(AppStorageKeys.double(AppStorageKeys.absServerSwitchedAt) == 7, "the moment of the switch moved")
            return AppStorageKeys.bool(AppStorageKeys.absMoreThanOneServer, default: false)
        }
        // The shape 3.5.1 left: two spellings of one server, the mark set.
        #expect(!move(register: ["https://ABS.example.com/", "https://abs.example.com:443"], signedIn: "https://abs.example.com/"),
                "one server under two spellings still cleans no book")
        #expect(move(register: ["https://abs.example.com", "https://other.example.com"], signedIn: "https://abs.example.com"),
                "a real second server lost its mark")
        #expect(move(register: [], signedIn: "https://abs.example.com"), "an empty register is no evidence")
        #expect(move(register: ["https://abs.example.com"], signedIn: "https://other.example.com"),
                "a server signed in that the register does not name")
        #expect(move(register: ["https://abs.example.com"], signedIn: nil), "no server signed in")
        #expect(ABSServerScope.secondServerShown(registered: ["https://A.example.com:443/"], signedIn: "https://a.example.com") == false)
    }

    /// The register travels: a removal by hand on another device arrives as
    /// `forget` here. Once the first start looked, no later start lowers a
    /// mark that stands rightly, whatever the register then shows.
    @Test("die Marke wird einmal je Geraet zurueckgenommen: nach einer Loeschung im Register bleibt eine zu Recht gesetzte Marke beim naechsten Start")
    func theMarkIsReviewedOncePerDevice() {
        let saved = Saved()
        defer { saved.restore() }
        let x = "https://x.example.com", y = "https://y.example.com"
        // The register as stored, without its notice to the cloud.
        func register(_ urls: [String]) {
            let entries = urls.map { KnownServer(url: $0, service: .audiobookshelf, lastSuccessAt: 1) }
            AppStorageKeys.set(try? JSONEncoder().encode(entries), for: KnownServers.storeKey)
        }
        AppStorageKeys.set(nil, for: AppStorageKeys.absSpellingMarkReviewed)
        AppStorageKeys.set(nil, for: AppStorageKeys.absSignedInServer)
        AppStorageKeys.set(nil, for: AppStorageKeys.absMoreThanOneServer)
        // Signed in at X, then at Y: the mark stands rightly.
        register([x, y])
        AppStorageKeys.noteABSSignIn(x, nowMs: 1)
        AppStorageKeys.noteABSSignIn(y, nowMs: 2)
        AppStorageKeys.normalizeABSServers()
        #expect(AppStorageKeys.bool(AppStorageKeys.absMoreThanOneServer, default: false), "the first start took a right mark")
        #expect(AppStorageKeys.bool(AppStorageKeys.absSpellingMarkReviewed, default: false), "the first start did not note its look")
        // Another device takes X out of the list, it arrives here; the next start.
        register([y])
        AppStorageKeys.normalizeABSServers()
        #expect(AppStorageKeys.bool(AppStorageKeys.absMoreThanOneServer, default: false),
                "a removal on another device lowered a right mark, the next full load would clean the books of X")
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

    @Test("ein Eintrag ohne Server, dessen Buch Server A gehoert, wartet unter B, auch wenn B das Buch kennt")
    func anOlderEntryOfAnOwnedBookWaits() async throws {
        let saved = Saved()
        defer { saved.restore() }
        let (queue, directory) = try queue()
        defer { try? FileManager.default.removeItem(at: directory) }
        let book = "switch-owned-\(UUID().uuidString)"
        let now = Date().timeIntervalSince1970 * 1000
        AppStorageKeys.set(nil, for: AppStorageKeys.absSignedInServer)
        await queue.enqueue(itemId: book, currentTime: 77, duration: 1000, isFinished: false)
        #expect(queue.pendingUpdate(itemId: book)?.server == nil, "the precondition: an entry without a server")
        var owners = ItemOwnerShelf.app?.read().value ?? ItemOwners()
        owners.noteFullLoad(ids: [book], server: "https://a.example")
        ItemOwnerShelf.app?.write(owners, afterCorruptRead: false)
        AppStorageKeys.noteABSSignIn("https://b.example", nowMs: now)
        let serverB = Server(books: [book])
        await queue.flush { _ in ProgressTarget(key: "abs", client: serverB) }
        #expect(serverB.sent[book] == nil, "a stand of A's book went to B")
        #expect(queue.pendingUpdate(itemId: book)?.currentTime == 77, "the stand of A's book left the queue under B")
    }
}
#endif
