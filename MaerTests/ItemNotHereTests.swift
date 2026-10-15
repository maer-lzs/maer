// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// A title no source on this device can name is said in words, never as a
/// made-up status code; an open nobody asked for says nothing to the person;
/// and the episode the takeover ladder found stays in the stock it was
/// found for.
@MainActor
struct ItemNotHereTests {
    final class Fetches { var count = 0 }

    @Test("TF-2: jeder Fall hat einen Satz, keiner nennt Domain, Typ oder Code")
    func eachCaseHasASentence() {
        for failure in [ItemNotHere.episodeNotLoadedHere, .episodeNotOnServer, .fileGone] {
            let sentence = failure.errorDescription ?? ""
            #expect(!sentence.isEmpty, "\(failure) has no sentence")
            #expect(failure.localizedDescription == sentence, "the system's text is the sentence")
            for word in ["404", "400", "Provider", "ItemNotHere", "error"] {
                #expect(!sentence.contains(word), "\(failure) says \(word)")
            }
        }
    }

    @Test("TF-4: nur eine Geste sagt einen Fehlschlag, Spiegel und Wiederherstellung nie")
    func onlyAGestureSaysAFailure() {
        #expect(PlayerCoordinator.OpenOrigin.gesture.saysFailure)
        #expect(!PlayerCoordinator.OpenOrigin.mirror.saysFailure)
        #expect(!PlayerCoordinator.OpenOrigin.restore.saysFailure)
    }

    static func show(_ url: URL, episodes: Range<Int>) -> PodcastShow {
        PodcastShow(id: PodcastSubscriptions.feedKey(url.absoluteString), title: "Held",
                    author: nil, artworkURL: nil, description: nil,
                    feedURL: url.absoluteString,
                    episodes: episodes.map {
                        PodcastEpisode(guid: "rss:held:\(url.lastPathComponent)-\($0)", title: "Ep \($0)",
                                       audioURL: "https://held.example/\($0).mp3",
                                       pubDate: Double($0 + 1), duration: 60)
                    })
    }

    @Test("TF-4: was die Leiter im Feed gefunden hat, steht danach im Bestand und oeffnet ohne zweiten Abruf")
    func whatTheLadderFoundStaysInTheStock() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("item-not-here-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let suite = "item-not-here-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: folder)
        }
        let subs = PodcastSubscriptions(
            fileURL: folder.appendingPathComponent("podcast_subscriptions.json"),
            database: MaerDatabase(path: folder.appendingPathComponent("maer.sqlite").path),
            defaults: defaults, isTheApp: false)
        await subs.ensureLoaded()
        let feed = try #require(URL(string: "https://held.example/\(UUID().uuidString.prefix(8))/feed.xml"))
        // The stock holds the two newest; the other device plays an older one.
        subs._testFeedFetcher = { url in .show(Self.show(url, episodes: 2..<4)) }
        try #require(await subs.subscribe(urlString: feed.absoluteString, notesCloud: false))
        let show = try #require(subs.shows.first)
        let wanted = "rss:held:\(feed.lastPathComponent)-0"
        try #require(subs.episode(guid: wanted) == nil, "the stock must lack the episode, or the case measures nothing")

        let fetches = Fetches()
        subs._testFeedFetcher = { url in
            await MainActor.run { fetches.count += 1 }
            return .show(Self.show(url, episodes: 0..<4))
        }
        let fresh = Self.show(feed, episodes: 0..<4)
        let added = await subs.absorb(fresh, showId: show.id)
        #expect(added == 2, "the two older episodes join the stock")
        #expect(subs.episode(guid: wanted)?.episode.title == "Ep 0", "the found episode is in the stock")
        #expect(subs.shows.first?.episodes.count == 4)
        #expect(fetches.count == 0, "absorbing asks the network nothing")
        #expect(await subs.absorb(fresh, showId: "feed:not-followed-here") == nil, "a show not followed here gains nothing")
        #expect(await subs.absorb(fresh, showId: show.id) == 0, "a second absorb adds nothing")
    }

    @Test("TF-6a: ist das Verzeichnis aus oder die Sendung hier nicht gefolgt, ist die Historie nicht gefragt: nil, nie 0")
    func anUnaskedHistoryIsNoFinding() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("history-nil-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let suite = "history-nil-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        // The directory switch lives in the app's settings: set it off and
        // put back exactly what was there.
        let key = AppStorageKeys.podcastIndexSourceEnabled
        let was = UserDefaults.standard.object(forKey: key)
        UserDefaults.standard.set(false, forKey: key)
        defer {
            if let was { UserDefaults.standard.set(was, forKey: key) } else { UserDefaults.standard.removeObject(forKey: key) }
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: folder)
        }
        try #require(!AppStorageKeys.podcastIndexActive, "the directory is still active, the case measures nothing")
        let subs = PodcastSubscriptions(
            fileURL: folder.appendingPathComponent("podcast_subscriptions.json"),
            database: MaerDatabase(path: folder.appendingPathComponent("maer.sqlite").path),
            defaults: defaults, isTheApp: false)
        await subs.ensureLoaded()
        let feed = try #require(URL(string: "https://held.example/\(UUID().uuidString.prefix(8))/feed.xml"))
        subs._testFeedFetcher = { url in .show(Self.show(url, episodes: 0..<2)) }
        try #require(await subs.subscribe(urlString: feed.absoluteString, notesCloud: false))
        let show = try #require(subs.shows.first)

        #expect(await subs.loadFullHistory(showId: show.id) == nil, "directory off: not asked, no finding")
        #expect(await subs.loadFullHistory(showId: "feed:not-followed-here") == nil, "not followed here: not asked either")
        #expect(subs.shows.first?.episodes.count == 2, "and the stock is untouched")
    }

    @Test("TF-6a: der Knopf fuer die Historie steht unter derselben Bedingung, unter der die Funktion fragt", .needsTheSources)
    func theHistoryButtonAsksWhatTheLoadAsks() throws {
        let page = SyncContractFenceTests.stripped(try String(
            contentsOf: SourceTree.root.appendingPathComponent("Sources/Views/Podcasts/PodcastShowView.swift"), encoding: .utf8))
        let store = SyncContractFenceTests.stripped(try String(
            contentsOf: SourceTree.root.appendingPathComponent("Sources/Providers/PodcastSubscriptions.swift"), encoding: .utf8))
        #expect(page.contains("if AppStorageKeys.podcastIndexActive, let show = liveShow {"), "the button asks the load's condition")
        #expect(!page.contains("podcastIndexConfigured"), "a key alone is not permission to ask")
        #expect(store.contains("guard AppStorageKeys.podcastIndexActive else {"))
    }

    @Test("TF-2: kein NSError mit erfundenem Code im Quellbaum", .needsTheSources)
    func noMadeUpStatusCodes() throws {
        // Each exception names its file and says why the code there is not
        // made up. None today.
        let exceptions: [String: String] = [:]
        let root = SourceTree.root.appendingPathComponent("Sources")
        let files = SourceTree.files(under: root)
            .filter { $0.pathExtension == "swift" }
        try #require(files.count > 100, "the fence did not read the source tree")
        var found: [String: Int] = [:]
        for file in files {
            let text = SyncContractFenceTests.stripped(try String(contentsOf: file, encoding: .utf8))
            let hits = text.components(separatedBy: "NSError(domain:").count - 1
            if hits > 0 { found[file.lastPathComponent] = hits }
        }
        #expect(Set(found.keys) == Set(exceptions.keys), "made-up NSError at \(found.sorted { $0.key < $1.key })")
    }

    @Test("TF-4: der Koordinator setzt loadError nur ueber die eine Ausgangstuer, und die Leiter legt ab, was sie fand", .needsTheSources)
    func theCoordinatorSpeaksThroughOneExit() throws {
        let file = SourceTree.root.appendingPathComponent("Sources/ViewModels/PlayerCoordinator.swift")
        let text = SyncContractFenceTests.stripped(try String(contentsOf: file, encoding: .utf8))
        let flat = text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        let writes = flat.components(separatedBy: "loadError = ").dropFirst().map { String($0.prefix(8)) }
        #expect(writes.filter { !$0.hasPrefix("nil") } == ["sentence"],
                "every sentence goes through openFailed, which asks the origin; found \(writes)")
        #expect(flat.contains("guard origin.saysFailure else { return } sayOpenFailure(sentence, cause: cause, title: item.title)"),
                "the exit no longer asks the origin before it speaks")
        #expect(flat.contains("if fetched != nil { await subscriptions.absorb(fresh, showId: showId) }"),
                "the ladder keeps what its fetch found")
    }
}
#endif
