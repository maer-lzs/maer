// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// A cloud store that counts what is written to it, so a witness can say
/// that a settled pair of devices writes nothing.
final class CountingChoiceCloud: UserChoiceCloudStore {
    var storage: [String: Any] = [:]
    var writes = 0
    func dictionary(forKey key: String) -> [String: Any]? { storage[key] as? [String: Any] }
    func array(forKey key: String) -> [Any]? { storage[key] as? [Any] }
    func set(_ value: Any?, forKey key: String) { writes += 1; storage[key] = value }
    func synchronize() -> Bool { true }
    var dictionaryRepresentation: [String: Any] { storage }
    func removeObject(forKey key: String) { writes += 1; storage[key] = nil }
}

/// Die Folgen-Grenze ist weg: keine Anzahl nimmt einer Sendung eine Folge,
/// ihre Schluessel reisen nicht mehr und verschwinden ohne Grabstein, eine
/// fertig gehoerte automatische Folge geht nach einem Tag, und die ganze
/// Geschichte laedt auch auf einer gestoeberten Sendung.
@MainActor
struct EpisodeLimitRetiredTests {
    static func show(_ url: URL, episodes: Range<Int>) -> PodcastShow {
        PodcastShow(id: PodcastIdentity.feedKey(url.absoluteString), title: "Grenze",
                    author: nil, artworkURL: nil, description: nil,
                    feedURL: url.absoluteString,
                    episodes: episodes.map {
                        PodcastEpisode(guid: "rss:limit:\(url.pathComponents[1])-\($0)", title: "Ep \($0)",
                                       audioURL: "https://limit.example/\($0).mp3",
                                       pubDate: Double($0 + 1) * 1000, duration: 600)
                    })
    }

    private func store(in folder: URL, defaults: UserDefaults) -> PodcastSubscriptions {
        PodcastSubscriptions(
            fileURL: folder.appendingPathComponent("podcast_subscriptions.json"),
            database: MaerDatabase(path: folder.appendingPathComponent("maer.sqlite").path),
            defaults: defaults, isTheApp: false)
    }

    private func device(_ cloud: CountingChoiceCloud, now: Double)
        -> (sync: UserChoiceCloudSync, defaults: UserDefaults, suite: String) {
        let suite = "limit-retired-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        var clock = now
        let sync = UserChoiceCloudSync(defaults: defaults, cloud: cloud, syncEnabled: { true },
                                       now: { clock += 1; return clock }, idFormSettled: { true })
        return (sync, defaults, suite)
    }

    private func blob(_ cloud: CountingChoiceCloud) -> [String: Any] {
        cloud.storage[UserChoiceCloudSync.blobKey] as? [String: Any] ?? [:]
    }

    /// What a device on an older build writes: a limit for one show and for
    /// all shows, as statements in the document.
    private func oldBuildWrites(_ cloud: CountingChoiceCloud, showKey: String, t: Double) {
        var document = blob(cloud)
        document[showKey] = UserChoiceEntry(value: .int(5), t: t).plist
        document["podcastEpisodeLimitAll"] = UserChoiceEntry(value: .int(5), t: t).plist
        // The master switch of the free catalogues, retired beside the limit.
        document["freeCatalogsMasterEnabled"] = UserChoiceEntry(value: .bool(false), t: t).plist
        cloud.storage[UserChoiceCloudSync.blobKey] = document
    }

    @Test("I1: ein Auffrischen nimmt keiner Sendung eine Folge, auch mit einer alten Grenze auf dem Geraet, und eine angefangene bleibt")
    func aRefreshTakesNothing() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("limit-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let suite = "limit-refresh-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let closeTheGate = PodcastPublishCountTests.openTheRSSGate()
        let run = UUID().uuidString.prefix(8)
        let feed = try #require(URL(string: "https://limit.example/\(run)/feed.xml"))
        let showId = PodcastIdentity.feedKey(feed.absoluteString)
        // A limit an older build left behind, where the old code read it.
        let oldKeys = ["podcastEpisodeLimit.\(showId)", "podcastEpisodeLimitAll"]
        for key in oldKeys { UserDefaults.standard.set(5, forKey: key) }
        defer {
            closeTheGate()
            for key in oldKeys { UserDefaults.standard.removeObject(forKey: key) }
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: folder)
        }
        try #require(AppStorageKeys.rssActive, "das RSS-Tor ist trotz Setzen zu, der Fall misst nichts")
        let subs = store(in: folder, defaults: defaults)
        await subs.ensureLoaded()
        subs._testFeedFetcher = { url in .show(Self.show(url, episodes: 0..<20)) }
        try #require(await subs.subscribe(urlString: feed.absoluteString, notesCloud: false))
        let oldest = try #require(subs.shows.first?.episodes.min { $0.pubDate < $1.pubDate })
        ListeningStore.store(oldest.guid, entry: [120, Date().timeIntervalSince1970 * 1000, 600], in: defaults)
        try #require(subs.shows.first?.episodes.count == 20)

        await subs.refreshAll()

        #expect(subs.shows.first?.episodes.count == 20, "no count takes an episode out of the show")
        #expect(subs.shows.first?.episodes.contains { $0.guid == oldest.guid } == true,
                "the begun episode, the oldest, is still in the show")
        #expect(ListeningStore.backup(oldest.guid, in: defaults) != nil, "and its position is still there")
    }

    @Test("Geschnittene Folgen kommen mit dem naechsten Auffrischen aus dem Feed zurueck")
    func aRefreshBringsTheFeedBack() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("limit-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let suite = "limit-back-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let closeTheGate = PodcastPublishCountTests.openTheRSSGate()
        defer {
            closeTheGate()
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: folder)
        }
        try #require(AppStorageKeys.rssActive, "das RSS-Tor ist trotz Setzen zu, der Fall misst nichts")
        let feed = try #require(URL(string: "https://limit.example/\(UUID().uuidString.prefix(8))/feed.xml"))
        let subs = store(in: folder, defaults: defaults)
        await subs.ensureLoaded()
        // The stock a limit of five left: the five newest of thirty.
        subs._testFeedFetcher = { url in .show(Self.show(url, episodes: 25..<30)) }
        try #require(await subs.subscribe(urlString: feed.absoluteString, notesCloud: false))
        try #require(subs.shows.first?.episodes.count == 5)
        subs._testFeedFetcher = { url in .show(Self.show(url, episodes: 0..<30)) }

        await subs.refreshAll()

        #expect(subs.shows.first?.episodes.count == 30, "the feed carries all thirty, the union holds them")
    }

    @Test("I1: die Grenze reist nicht mehr, zwei Geraete raeumen sie ohne Grabstein und schreiben danach nichts")
    func twoDevicesRetireTheLimit() throws {
        let cloud = CountingChoiceCloud()
        let a = device(cloud, now: 10_000)
        let b = device(cloud, now: 20_000)
        defer {
            UserDefaults().removePersistentDomain(forName: a.suite)
            UserDefaults().removePersistentDomain(forName: b.suite)
        }
        let showKey = "podcastEpisodeLimit.feed:retired"
        oldBuildWrites(cloud, showKey: showKey, t: 5_000)
        // A held the limit already, with its stamp, as before the update.
        a.defaults.set(5, forKey: showKey)
        a.sync._seedStampsForWitness([showKey: 5_000.0])
        try #require(blob(cloud)[showKey] != nil, "the document carries the limit, else the case measures nothing")

        for side in [a, b] {
            side.sync.forgetRetired()
            side.sync.reconcile()
        }

        for key in [showKey, "podcastEpisodeLimitAll", "freeCatalogsMasterEnabled"] {
            #expect(blob(cloud)[key] == nil, "\(key) left the document, no tombstone stays behind")
            #expect(a.defaults.object(forKey: key) == nil, "A forgot \(key)")
            #expect(b.defaults.object(forKey: key) == nil, "B did not adopt \(key)")
            #expect(a.sync.localStamps() != nil && b.sync.localStamps() != nil, "the precondition: the stamps are read")
            #expect(a.sync.localStamps()?[key] == nil && b.sync.localStamps()?[key] == nil, "no stamp for \(key)")
        }

        cloud.writes = 0
        for _ in 0..<2 {
            for side in [a, b] {
                side.sync.forgetRetired()
                side.sync.reconcile()
            }
        }
        #expect(cloud.writes == 0, "settled: two more rounds on both devices write nothing")

        // An older build writes the limit again. The new build clears it with
        // one write and takes nothing over; the other device has nothing left
        // to do.
        oldBuildWrites(cloud, showKey: showKey, t: 30_000)
        cloud.writes = 0
        b.sync.reconcile()
        #expect(cloud.writes == 1, "one write takes it out again")
        #expect(b.defaults.object(forKey: showKey) == nil, "B adopts nothing from the older build")
        a.sync.reconcile()
        #expect(cloud.writes == 1, "A finds nothing to do")
        #expect(blob(cloud)[showKey] == nil && blob(cloud)["podcastEpisodeLimitAll"] == nil)
        #expect(blob(cloud)["freeCatalogsMasterEnabled"] == nil, "the retired master switch came back")
    }

    @Test("I1: die Schluessel der Grenze stehen nur noch im Ruhestand des Katalogs, kein Pfad schneidet", .needsTheSources)
    func nothingTrimsAnyMore() throws {
        #expect(UserChoiceCatalog.isRetired("podcastEpisodeLimit.feed:x"))
        #expect(UserChoiceCatalog.isRetired("podcastEpisodeLimitAll"))
        #expect(UserChoiceCatalog.isRetired("freeCatalogsMasterEnabled"))
        #expect(!UserChoiceCatalog.travelingScalars.contains(where: UserChoiceCatalog.isRetired))
        #expect(!UserChoiceCatalog.travelingPrefixes.contains(where: UserChoiceCatalog.isRetired))
        #expect(!PodcastShowPreferences.travellingKeys(showId: "feed:x").contains(where: UserChoiceCatalog.isRetired))
        let root = SourceTree.root.appendingPathComponent("Sources")
        let files = SourceTree.files(under: root)
            .filter { $0.pathExtension == "swift" }
        try #require(files.count > 100, "the fence did not read the source tree")
        var found: [String: [String]] = [:]
        for file in files {
            let text = SyncContractFenceTests.stripped(try String(contentsOf: file, encoding: .utf8))
            for word in ["applyLimit", "trimEpisodes", "keepLatest", "podcastEpisodeLimit"] where text.contains(word) {
                found[file.lastPathComponent, default: []].append(word)
            }
        }
        #expect(found == ["UserChoiceSync.swift": ["podcastEpisodeLimit"]], "\(found)")
        let sync = SyncContractFenceTests.stripped(try String(
            contentsOf: root.appendingPathComponent("Networking/UserChoiceCloudSync.swift"), encoding: .utf8))
        let start = try #require(functionBody(of: "func start() {", in: sync))
        let forget = try #require(start.range(of: "forgetRetired()"))
        let gate = try #require(start.range(of: "guard syncEnabled() else { return }"))
        #expect(forget.lowerBound < gate.lowerBound, "a device that does not sync forgets the limit too")
    }

    /// The cases live in `Fixtures/Shared/abos/episode-expired.json`, read
    /// by Swift and Kotlin alike: the day after finishing, and which own
    /// downloads may go now.
    nonisolated static let expiry = SharedCases.cases("episode-expired")

    @Test("gemeinsame Faelle: episode-expired traegt zwei Faelle")
    func expiryCasesLoaded() {
        #expect(Self.expiry.count == 2)
    }

    @Test("gemeinsame Faelle: eine fertig gehoerte automatische Folge geht je Fall wie die Datei sagt", arguments: expiry)
    func expired(_ c: SharedCase) throws {
        switch c.ask {
        case "keepAfterFinish":
            #expect(Int(PodcastAutoDownloadRules.keepAfterFinish) == c["expect"]?.int, "\(c.slug)")
        case "expired":
            let input = try c.value("input")
            let items = try #require(input["items"]?.array).map {
                PodcastAutoDownloadRules.Item(id: $0["id"]?.string ?? "", isFinished: $0["isFinished"]?.bool ?? false,
                                              finishedAt: Double($0["finishedAt"]?.int ?? 0))
            }
            let expired = PodcastAutoDownloadRules.expired(items, ownedByAutomation: Set(input["owned"]?.strings ?? []),
                                                           now: Double(try #require(input["now"]?.int)))
            #expect(expired == c["expect"]?.strings, "\(c.slug)")
        default:
            Issue.record("\(c.slug): unknown ask \(c.ask)")
        }
    }

    @Test("I5: die ganze Geschichte einer gestoeberten Sendung liefert Folgen oder einen Fehlschlag, und schreibt nichts")
    func browsedHistoryAnswers() async throws {
        let url = try #require(URL(string: "https://limit.example/browsed/feed.xml"))
        let key = PodcastIdentity.feedKey(url.absoluteString)
        // The feed's ids have the form the directory's answer maps to, so the
        // known episode is recognised as known.
        var browsed = Self.show(url, episodes: 0..<2)
        browsed.episodes = browsed.episodes.enumerated().map { index, episode in
            var mapped = episode
            mapped.guid = "rss:\(key):ep-\(index)"
            return mapped
        }
        let known = try #require(browsed.episodes.first)
        let answer = [
            PodcastIndexEpisode(guid: "ep-0", title: "Known",
                                enclosureUrl: known.audioURL, datePublished: 1, duration: 60,
                                description: nil, image: nil),
            PodcastIndexEpisode(guid: "old-a", title: "Old A", enclosureUrl: "https://limit.example/a.mp3",
                                datePublished: 0.5, duration: 60, description: nil, image: ""),
            PodcastIndexEpisode(guid: "old-b", title: "Old B", enclosureUrl: "https://limit.example/b.mp3",
                                datePublished: 0.25, duration: 60, description: nil, image: nil),
        ]
        let added = try #require(await PodcastSubscriptions.historyAdditions(of: browsed, browsed: true) { _ in answer })
        #expect(added.map(\.guid) == ["rss:\(key):old-a", "rss:\(key):old-b"], "only what the show lacks, newest first")

        struct DirectoryDown: Error {}
        let failed = await PodcastSubscriptions.historyAdditions(of: browsed, browsed: true) { _ in throw DirectoryDown() }
        #expect(failed == nil, "a failed lookup is no finding")
    }

    @Test("I5: die Seite laedt fuer eine gestoeberte Sendung ueber den Weg fuer den Besuch, nie ueber den Abo-Speicher", .needsTheSources)
    func thePageLoadsTheBrowsedHistory() throws {
        let page = SyncContractFenceTests.stripped(try String(
            contentsOf: SourceTree.root.appendingPathComponent("Sources/Views/Podcasts/PodcastShowView.swift"), encoding: .utf8))
        // The surface, not only the way that loads: the section stands under
        // the capability, and a browsed show has it. It had not, and the
        // button never showed on a browsed show, while this witness read only
        // the way that loads.
        #expect(PodcastShowCapabilities.of(.browsed).fetchesMoreEpisodes, "the button stands on a browsed show")
        let flat = page.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        #expect(flat.contains("if caps.fetchesMoreEpisodes { Group { if isServerShow { availableSection } else { historySection } }"),
                "the history section is the one the capability opens")
        let load = try #require(functionBody(of: "private func loadHistory(", in: page))
        #expect(load.contains("guard mode == .browsed else { return await subs.loadFullHistory(showId: show.id) }"))
        #expect(load.contains("await PodcastSubscriptions.browsedHistory(of: show)"))
        #expect(load.contains("BrowsedEpisodes.shared.remember(show: history.show)"), "the episodes play")
        #expect(load.contains("return history.added"), "success says how many, never the failure sentence")
        let section = try #require(functionBody(of: "private var historySection: some View {", in: page))
        #expect(section.contains("switch await loadHistory(show) {"))
        let store = SyncContractFenceTests.stripped(try String(
            contentsOf: SourceTree.root.appendingPathComponent("Sources/Providers/PodcastSubscriptions.swift"), encoding: .utf8))
        let browsed = try #require(functionBody(of: "static func browsedHistory(", in: store))
        #expect(browsed.contains("guard AppStorageKeys.podcastIndexActive else {"), "the same gate as for a followed show")
        #expect(!browsed.contains("save()") && !browsed.contains("shows["), "nothing is stored")
    }
}
#endif
