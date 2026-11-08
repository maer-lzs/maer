// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// A feed's stored sign-in that the keychain cannot give out now (the
/// device not unlocked since it started) is not "no sign-in": the fetch
/// does not go out without it, a follow that depends on it is not asked
/// and not marked, and a rule's picture stays home. With a sign-in there
/// and with none, each way works as before.
@MainActor
struct FeedAccessUnknownTests {
    /// The keychain of one feed for the witness: `read` for `feedKey`,
    /// nothing for every other.
    static func keychain(_ feedKey: String, _ read: KeychainRead) -> @Sendable (String) -> KeychainRead {
        { $0 == feedKey ? read : .missing }
    }

    @Test("ein Zugang hat drei Antworten: da, keiner, gerade nicht lesbar")
    func theThreeAnswers() {
        let table: [(KeychainRead, PodcastFeedAuth.Access)] = [
            (.value("anna\ngeheim"), .present(user: "anna", password: "geheim")),
            (.value("ohne-trenner"), .absent),
            (.missing, .absent),
            (.undecodable, .absent),
            (.unreadable, .unknown),
        ]
        for (read, access) in table {
            #expect(PodcastFeedAuth.access(from: read) == access, "\(read) reads as \(access)")
        }
        let key = "feed-\(UUID().uuidString)"
        PodcastFeedAuth.$reading.withValue(Self.keychain(key, .unreadable)) {
            #expect(PodcastFeedAuth.access(feedKey: key) == .unknown)
            #expect(!PodcastFeedAuth.hasCredentials(feedKey: key), "an unreadable sign-in is no sign-in to show")
        }
        PodcastFeedAuth.$reading.withValue(Self.keychain(key, .value("anna\ngeheim"))) {
            #expect(PodcastFeedAuth.credentials(feedKey: key)?.user == "anna")
        }
    }

    @Test("die Kopfzeilen einer Folge haben drei Antworten, auch ueber das Protokoll und einen Weiterreicher")
    func theHeadersHaveThreeAnswers() {
        #expect(PodcastFeedAuth.headers(for: .present(user: "anna", password: "geheim"))
                == ["Authorization": "Basic YW5uYTpnZWhlaW0="])
        #expect(PodcastFeedAuth.headers(for: .absent) == [:])
        #expect(PodcastFeedAuth.headers(for: .unknown) == nil)
        let key = "feed-\(UUID().uuidString)"
        let episode = "rss:\(key):guid-1"
        // Asked through the protocol: a method that does not answer the
        // requirement would leave the default speaking.
        let rss: any AudioProvider = RSSProvider.shared
        PodcastFeedAuth.$reading.withValue(Self.keychain(key, .unreadable)) {
            #expect(rss.streamAuthHeaders(forItemId: episode) == nil, "an unreadable sign-in is not no sign-in")
        }
        PodcastFeedAuth.$reading.withValue(Self.keychain(key, .missing)) {
            #expect(rss.streamAuthHeaders(forItemId: episode) == [:])
        }
        PodcastFeedAuth.$reading.withValue(Self.keychain(key, .value("anna\ngeheim"))) {
            #expect(rss.streamAuthHeaders(forItemId: episode)?["Authorization"] == "Basic YW5uYTpnZWhlaW0=")
        }
        #expect(PodcastFeedAuth.streamHeaders(forItemId: "sub:song:1") == [:], "a title that is no episode needs none")
        let (union, _, jf) = MusicUnionTests.pair()
        jf.itemHeaders = nil
        let forwarder: any AudioProvider = union
        #expect(forwarder.streamAuthHeaders(forItemId: "jf:album:Dylan") == nil, "the union passes the unknown on")
        #expect(forwarder.streamAuthHeaders(forItemId: "sub:album:Abba") == [:], "and the other source's answer")
    }

    /// A source whose headers answer as set, counting every address it gives.
    final class LockedProvider: AudioProvider {
        let headers: [String: String]?
        /// False: the source gives no address, a start fails for another
        /// reason than the sign-in.
        let givesAddresses: Bool
        private(set) var addressesAsked = 0
        init(headers: [String: String]?, givesAddresses: Bool = true) {
            self.headers = headers
            self.givesAddresses = givesAddresses
        }
        var providerId: String { "locked" }
        var keepsMarksOnDevice: Bool { true }
        var capabilities: ProviderCapabilities { [.downloadable] }
        var streamAuthHeaders: [String: String] { [:] }
        func streamAuthHeaders(forItemId itemId: String) -> [String: String]? { headers }
        func fetchLibraries() async throws -> [ABSLibrary] { [] }
        func fetchLibraryItems(libraryId: String) async throws -> [LibraryItem] { [] }
        func fetchItemDetail(itemId: String) async throws -> LibraryItemDetail {
            throw NSError(domain: "locked", code: 404)
        }
        func coverURL(forItemId itemId: String) -> URL? { nil }
        func streamURL(forContentPath contentPath: String) -> URL? {
            addressesAsked += 1
            return givesAddresses ? URL(string: "http://127.0.0.1:1/\(contentPath)") : nil
        }
        func fetchAllProgress() async throws -> [String: BookProgress] { [:] }
        func updateProgress(itemId: String, currentTime: Double, duration: Double, isFinished: Bool) async throws {}
        func fetchBookmarks(itemId: String) async throws -> [ABSBookmark] { [] }
        func createBookmark(itemId: String, time: Double, title: String) async throws {}
        func deleteBookmark(itemId: String, time: Double) async throws {}
    }

    @Test("ein Download mit unlesbarem Zugang fragt nichts und setzt keine Phase")
    func aDownloadWaitsForItsSignIn() async throws {
        let home = try DownloadNotifyCountTests.home()
        defer { try? FileManager.default.removeItem(at: home.directory) }
        await home.manager.ensureScanned()
        let id = "locked-\(UUID().uuidString)"
        // Tracks on the disk: a download that goes on asks each address and
        // fetches nothing.
        let detail = try DownloadNotifyCountTests.plant(id, tracks: 2, in: home)
        let locked = LockedProvider(headers: nil)
        await home.manager.download(item: detail, provider: locked, kind: nil)
        #expect(locked.addressesAsked == 0, "no address was asked, so no request went out")
        #expect(home.manager.phase[id] == nil, "nothing reads as failed: \(String(describing: home.manager.phase[id]))")
        #expect(!home.manager.downloadedItemIds.contains(id))
        let open = LockedProvider(headers: [:])
        await home.manager.download(item: detail, provider: open, kind: nil)
        #expect(open.addressesAsked == 2, "with the sign-in read the download goes on")
        #expect(home.manager.downloadedItemIds.contains(id))
    }

    @Test("ein Start mit unlesbarem Zugang fragt keinen Strom und zeigt den Ladefehler")
    func aStartWaitsForItsSignIn() async {
        let track = ABSAudioTrack(index: 0, startOffset: 0, duration: 600, contentUrl: "episode.mp3", metadata: nil)
        let detail = LibraryItemDetail(
            id: "locked-\(UUID().uuidString)",
            media: LibraryItemMedia(metadata: nil, duration: 600, chapters: nil, tracks: [track]),
            userMediaProgress: nil)
        let locked = PlayerViewModel(provider: LockedProvider(headers: nil))
        await locked.load(item: detail)
        #expect(locked.player == nil, "no queue, so no stream was requested")
        #expect(locked.sourceHint?.kind == .cannotPlay, "the start says it cannot play")
        let open = PlayerViewModel(provider: LockedProvider(headers: [:]))
        await open.load(item: detail)
        #expect(open.player != nil, "with the sign-in read the queue is built")
    }

    /// The sentence a start that cannot play shows, or nil.
    private static func cannotPlaySentence(_ model: PlayerViewModel) -> String? {
        if case .cannotPlay(let sentence) = model.sourceHint { return sentence }
        return nil
    }

    @Test("ein Start mit unlesbarem Zugang sagt, dass das Geraet einmal entsperrt werden muss; ohne Zugang und bei einem anderen Fehler bleibt es bei den bisherigen")
    func aLockedStartSaysToUnlock() async {
        let track = ABSAudioTrack(index: 0, startOffset: 0, duration: 600, contentUrl: "episode.mp3", metadata: nil)
        let detail = LibraryItemDetail(
            id: "locked-\(UUID().uuidString)",
            media: LibraryItemMedia(metadata: nil, duration: 600, chapters: nil, tracks: [track]),
            userMediaProgress: nil)
        let unknown = PlayerViewModel(provider: LockedProvider(headers: nil))
        await unknown.load(item: detail)
        #expect(Self.cannotPlaySentence(unknown) == String(localized: "Unlock this device once to play this episode."))
        let absent = PlayerViewModel(provider: LockedProvider(headers: [:]))
        await absent.load(item: detail)
        #expect(Self.cannotPlaySentence(absent) == nil, "without a sign-in the start goes on as before")
        let failed = PlayerViewModel(provider: LockedProvider(headers: [:], givesAddresses: false))
        await failed.load(item: detail)
        #expect(Self.cannotPlaySentence(failed) == String(localized: "Audiobook could not be loaded."),
                "another failure keeps its sentence")
    }

    /// A start without a track ends before the queue is built ("No playable
    /// track found."), so no start reaches a queue that is not built today.
    /// The fence keeps the mark of the queue before its first way out, so a
    /// queue that is not built never answers with the mark of the one before.
    @Test("die Marke der Warteschlange faellt vor ihrem ersten Ausgang", .needsTheSources)
    func theQueueMarkFallsBeforeItsFirstWayOut() throws {
        let file = try #require(ProjectFileIntegrityTests.sourceFiles().first { $0.lastPathComponent == "PlayerViewModel.swift" })
        let source = SyncContractFenceTests.stripped(try String(contentsOf: file, encoding: .utf8))
        let start = try #require(source.range(of: "private func buildQueue(startingAtTrackIndex"))
        let reset = try #require(source.range(of: "queueWaitedForSignIn = false", range: start.upperBound..<source.endIndex))
        let firstGuard = try #require(source.range(of: "guard ", range: start.upperBound..<source.endIndex))
        #expect(reset.lowerBound < firstGuard.lowerBound, "the mark of the queue before stays past its first way out")
    }

    @Test("ein Feed mit unlesbarem Zugang wird nicht ohne ihn gefragt")
    func aFeedIsNotAskedWithoutItsSignIn() async throws {
        // A closed port on the loopback: a request that goes out comes back
        // as unreachable at once.
        let url = try #require(URL(string: "https://127.0.0.1:9/feed-\(UUID().uuidString).xml"))
        let key = PodcastIdentity.feedKey(PodcastFeedAddress.upgraded(url).absoluteString)
        let locked = await PodcastFeedAuth.$reading.withValue(Self.keychain(key, .unreadable)) {
            await PodcastSubscriptions.fetchOutcome(feedURL: url, patience: .bulk)
        }
        guard case .accessUnknown = locked else {
            Issue.record("the feed was asked without its sign-in: \(locked)")
            return
        }
        let none = await PodcastFeedAuth.$reading.withValue(Self.keychain(key, .missing)) {
            await PodcastSubscriptions.fetchOutcome(feedURL: url, patience: .bulk)
        }
        if case .accessUnknown = none { Issue.record("a feed without a sign-in is asked as before") }
    }

    @Test("eine Uebernahme mit unlesbarem Zugang wird nicht gefragt und nicht vermerkt")
    func anAdoptionWaitsUnmarked() async throws {
        let (subs, defaults, cleanup) = try await BulkImportTests.storeAndDefaults()
        defer { cleanup() }
        let feed = "https://locked.example/\(UUID().uuidString.prefix(8))/feed.xml"
        subs._testFeedFetcher = { _ in .accessUnknown }
        let waiting = await subs.follow(urlString: feed, notesCloud: false, adopting: true, isSingleUserAct: false)
        #expect(waiting == .notAsked)
        #expect(FeedAdoptionPending.pending(defaults: defaults).isEmpty, "nothing marked, the next round asks again")
        #expect(subs.shows.isEmpty)
        // The control: a feed that was asked and failed is marked as before.
        subs._testFeedFetcher = { _ in .failed(.timeout) }
        _ = await subs.follow(urlString: feed, notesCloud: false, adopting: true, isSingleUserAct: false)
        #expect(FeedAdoptionPending.pending(defaults: defaults)[PodcastIdentity.feedKey(feed)]?.reason == .timeout)
    }

    @Test("der freie Zwilling einer Sendung mit unlesbarem Zugang wird weder abonniert noch uebersprungen")
    func aFreeTwinWaitsForThePaidShowsSignIn() async throws {
        let run = UUID().uuidString.prefix(8)
        let paid = "https://paid.example/\(run)/feed.xml"
        let free = "https://free.example/\(run)/feed.xml"
        let paidKey = PodcastIdentity.feedKey(paid)
        func follow(_ read: KeychainRead) async throws -> (PodcastSubscriptions.FollowOutcome, Bool, Bool) {
            let (subs, defaults, cleanup) = try await BulkImportTests.storeAndDefaults()
            defer { cleanup() }
            subs._testFeedFetcher = { url in .show(BulkImportTests.show(url, title: "Twin Show")) }
            return try await PodcastFeedAuth.$reading.withValue(Self.keychain(paidKey, read)) {
                try #require(await subs.subscribe(urlString: paid, notesCloud: false))
                let outcome = await subs.follow(urlString: free, notesCloud: false, adopting: true, isSingleUserAct: false)
                return (outcome, subs.shows.contains { $0.feedURL == free },
                        FeedAdoptionPending.pending(defaults: defaults).isEmpty)
            }
        }
        let locked = try await follow(.unreadable)
        #expect(locked.0 == .notAsked)
        #expect(!locked.1, "the free copy is not held next to the paid one")
        #expect(locked.2, "and not marked: the next round asks again")
        let signedIn = try await follow(.value("anna\ngeheim"))
        guard case .freeTwin = signedIn.0 else {
            Issue.record("with the sign-in read the twin is skipped as before: \(signedIn.0)")
            return
        }
        let noSignIn = try await follow(.missing)
        #expect(noSignIn.1, "without a sign-in the other show is followed as before")
    }

    @Test("das Abbild einer Regel laesst das Bild zu Hause, solange der Zugang unlesbar ist")
    func aRulesPictureStaysHomeWhileTheSignInIsUnread() throws {
        let feed = "https://paid.example/\(UUID().uuidString.prefix(8))/feed.xml"
        let key = PodcastIdentity.feedKey(feed)
        let id = try #require(RoutineRule(kind: .next(count: 2), feedKey: key)).id
        let show = PodcastShow(id: key, title: "Morgen", author: nil,
                               artworkURL: "https://cdn.example/cover.jpg", description: nil,
                               feedURL: feed, episodes: [])
        let answers: [(KeychainRead, Bool?)] = [(.unreadable, nil), (.value("anna\ngeheim"), true), (.missing, false)]
        for (read, premium) in answers {
            PodcastFeedAuth.$reading.withValue(Self.keychain(key, read)) {
                #expect(PodcastSubscriptions.premiumAnswer(feed, defaults: UserDefaults()) == premium, "\(read)")
            }
        }
        let unread = try #require(RoutinePlayback.snapshot(id, show: show, premium: nil))
        #expect(unread.title == "Morgen", "the title travels")
        #expect(unread.coverURL == nil, "the picture stays home while the paid state is unread")
        #expect(RoutinePlayback.snapshot(id, show: show, premium: false)?.coverURL == "https://cdn.example/cover.jpg")
    }

    @Test("jeder Leser des Zugangs eines Feeds liest ihn ueber die eine Stelle", .needsTheSources)
    func everyReaderOfAFeedsSignInGoesThroughTheOnePlace() throws {
        func code(_ relative: String) throws -> String {
            SyncContractFenceTests.stripped(try String(contentsOf: SourceTree.root.appendingPathComponent(relative), encoding: .utf8))
        }
        let source = try code("Sources/Networking/PodcastFeedAuth.swift")
        // The live item is read in one place only, through the seam.
        let liveReads = source.split(separator: "\n").filter {
            $0.contains("KeychainStore.read(forKey: key(") || $0.contains("KeychainStore.load(forKey: key(")
        }
        #expect(liveReads.count == 1 && liveReads.first?.contains("KeychainStore.read(forKey: key(feedKey))") == true,
                "one read of the live item: \(liveReads)")
        let credentials = try #require(source.range(of: "static func credentials(feedKey: String)"))
        let body = String(source[credentials.lowerBound...].prefix(300))
        #expect(body.contains("access(feedKey: feedKey)") && !body.contains("KeychainStore"),
                "the credentials come from the three answers")
        // No other file can name the live item to read it past the place.
        var namers: [String] = []
        var seen: Set<String> = []
        for file in SourceTree.files(under: SourceTree.root.appendingPathComponent("Sources"))
        where file.pathExtension == "swift" && file.lastPathComponent != "PodcastFeedAuth.swift" {
            seen.insert(file.lastPathComponent)
            if try String(contentsOf: file, encoding: .utf8).contains("\"feedAuth.") { namers.append(file.lastPathComponent) }
        }
        #expect(seen.contains("PodcastSubscriptions.swift") && seen.contains("FeedAuthSync.swift"),
                "the readers of the access were among the files read")
        #expect(namers.isEmpty, "the live item is named outside its place: \(namers)")
        let subscriptions = try code("Sources/Providers/PodcastSubscriptions.swift")
        let fetch = try #require(subscriptions.range(of: "static func fetchOutcome(feedURL rawURL: URL"))
        let fetchBody = String(subscriptions[fetch.lowerBound...].prefix(1400))
        #expect(fetchBody.contains("PodcastFeedAuth.access(feedKey:") && !fetchBody.contains("authHeader("),
                "the fetch asks the three answers, not the header that reads unknown as none")
    }

    /// The files that answer the headers per title, each declaration with
    /// the three answers.
    static let headerAnswerers: [String: (count: Int, reason: String)] = [
        "AudioProvider.swift": (2, "the requirement and its default, the source's own headers, always known"),
        "MusicUnion.swift": (1, "forwards to the title's own source and returns its answer as it is"),
        "RSSProvider.swift": (1, "a feed's Basic auth through PodcastFeedAuth.streamHeaders"),
    ]

    /// The readers of a feed's sign-in outside its place that read an
    /// unreadable one as none, each with why that is no request without it.
    static let signInReaders: [String: (count: Int, reason: String)] = [
        "PodcastSubscriptions.swift": (1, "the reason for a status after a fetch that went out, so its access was read"),
        "PodcastSourceView.swift": (4, "adding a feed and its login sheet show and take over a stored login, on screens only an unlocked device shows"),
        "PremiumFeedsSection.swift": (1, "the class label of a managed feed, on a screen only an unlocked device shows"),
        "PodcastShowView.swift": (1, "the remedy of a refused show, on a screen only an unlocked device shows"),
    ]

    @Test("jede Antwort der Kopfzeilen traegt die drei Antworten, keiner faltet sie, jeder Leser des Zugangs steht im Bestand", .needsTheSources)
    func everyHeaderAnswerKeepsTheUnknown() {
        var answerers: [String: Int] = [:]
        var twoAnswers: [String] = []
        var folds: [String] = []
        var readers: [String: Int] = [:]
        var seen = false
        for (file, text) in ProjectFileIntegrityTests.sourceTexts() {
            if file == "DownloadManager.swift" { seen = true }
            for line in SyncContractFenceTests.stripped(text).split(separator: "\n") {
                if line.contains("func streamAuthHeaders(forItemId") {
                    answerers[file, default: 0] += 1
                    if !line.contains("-> [String: String]?") { twoAnswers.append("\(file): \(line)") }
                }
                // A `??` after the call, not one inside its argument.
                if line.contains(#/streamAuthHeaders\(forItemId:[^)]*\)\s*\?\?/#) { folds.append("\(file): \(line)") }
                if file != "PodcastFeedAuth.swift",
                   line.contains("PodcastFeedAuth.credentials(") || line.contains("PodcastFeedAuth.hasCredentials(") {
                    readers[file, default: 0] += 1
                }
                if line.contains("authHeader(feedKey:") || line.contains("authHeader(forItemId:") {
                    folds.append("\(file): \(line)")
                }
            }
        }
        #expect(seen, "the callers of the headers were among the files read")
        #expect(answerers == Self.headerAnswerers.mapValues(\.count), "the answerers of the headers: \(answerers)")
        #expect(twoAnswers.isEmpty, "an answer without the unknown: \(twoAnswers)")
        #expect(folds.isEmpty, "the unknown is folded into none: \(folds)")
        #expect(readers == Self.signInReaders.mapValues(\.count), "the readers of a feed's sign-in: \(readers)")
    }
}
#endif
