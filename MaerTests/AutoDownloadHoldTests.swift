// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// The automation keeps a chosen count per show: what lies above the count
/// goes, the one furthest from the direction first, never a started one
/// or the playing one. The direction travels, on/off and count stay on the
/// device, and the move from the old single value writes nothing.
@MainActor
struct AutoDownloadHoldTests {
    typealias Rules = PodcastAutoDownloadRules

    /// The cases live in `Fixtures/Shared/abos/auto-download-hold.json`, read
    /// by Swift and Kotlin alike: newest and in order from five to one, a
    /// begun episode never goes, the standby episode stays and the new one
    /// waits, a news show keeps only the newest, under the count fills.
    nonisolated static let holds = SharedCases.cases("auto-download-hold")

    @Test("shared cases: auto-download-hold carries six cases")
    func holdCasesLoaded() {
        #expect(Self.holds.count == 6)
    }

    @Test("shared cases: hold answers per case as the file says", arguments: holds)
    func hold(_ c: SharedCase) throws {
        let input = try c.value("input")
        let downloaded = input["downloaded"]?.strings
        let all = input["downloaded"]?.string == "all"
        let own = try #require(input["own"]?.array).map {
            Rules.Owned(id: $0["id"]?.string ?? "", pubDate: Double($0["pubDate"]?.int ?? 0),
                        isProtected: $0["isProtected"]?.bool ?? false)
        }
        let directionName = try #require(input["direction"]?.string)
        let direction = try #require(Rules.Direction(rawValue: directionName))
        let hold = Rules.hold(wanted: input["wanted"]?.strings ?? [],
                              isDownloaded: { all || (downloaded ?? []).contains($0) },
                              own: own, direction: direction, limit: try #require(input["limit"]?.int))
        let expect = try c.value("expect")
        #expect(hold.fetch == expect["fetch"]?.strings, "\(c.slug) fetch")
        #expect(hold.drop == expect["drop"]?.strings, "\(c.slug) drop")
    }

    // MARK: - The values and where they live

    private func suite() -> (defaults: UserDefaults, name: String) {
        let name = "auto-hold-\(UUID().uuidString)"
        return (UserDefaults(suiteName: name)!, name)
    }

    private func snapshot(_ defaults: UserDefaults, _ name: String) -> NSDictionary {
        (defaults.persistentDomain(forName: name) ?? [:]) as NSDictionary
    }

    @Test("the old single value is split on reading, every form keeps its effect, and nothing is written")
    func theOldValueSplitsWhenRead() {
        let (defaults, name) = suite()
        defer { UserDefaults().removePersistentDomain(forName: name) }
        // Every form the builds before wrote, per show and for all shows.
        defaults.set("off", forKey: "podcastAutoDownloadMode.feed:off")
        defaults.set(false, forKey: PodcastAutoDownload.flagKey("feed:off"))
        defaults.set("newest", forKey: "podcastAutoDownloadMode.feed:newest")
        defaults.set(true, forKey: PodcastAutoDownload.flagKey("feed:newest"))
        defaults.set("inOrder", forKey: "podcastAutoDownloadMode.feed:inorder")
        defaults.set(true, forKey: PodcastAutoDownload.flagKey("feed:inorder"))
        defaults.set("inOrder", forKey: "podcastAutoDownloadModeAll")
        let before = snapshot(defaults, name)
        #expect(before.count == 7, "the stock is in the suite, else the case measures nothing")

        #expect(!PodcastAutoDownload.isEnabled("feed:off", defaults: defaults))
        #expect(PodcastAutoDownload.storedDirection("feed:off", defaults: defaults) == nil,
                "off carries no direction of its own")
        #expect(PodcastAutoDownload.isEnabled("feed:newest", defaults: defaults))
        #expect(PodcastAutoDownload.direction("feed:newest", defaults: defaults) == .newest)
        #expect(PodcastAutoDownload.isEnabled("feed:inorder", defaults: defaults))
        #expect(PodcastAutoDownload.direction("feed:inorder", defaults: defaults) == .inOrder)
        // A show without its own value follows all shows: on, in order.
        #expect(PodcastAutoDownload.isEnabled("feed:follows", defaults: defaults))
        #expect(PodcastAutoDownload.direction("feed:follows", defaults: defaults) == .inOrder)
        #expect(PodcastAutoDownload.direction("feed:off", defaults: defaults) == .inOrder)
        #expect(PodcastAutoDownload.keep("feed:follows", defaults: defaults) == Rules.keepByDefault)

        #expect(snapshot(defaults, name) == before, "reading the old value wrote nothing")
    }

    @Test("a new value wins over the old one, a traveling direction beats the old value of the device")
    func aNewValueWins() {
        let (defaults, name) = suite()
        defer { UserDefaults().removePersistentDomain(forName: name) }
        defaults.set("inOrder", forKey: "podcastAutoDownloadMode.feed:x")
        defaults.set(true, forKey: PodcastAutoDownload.flagKey("feed:x"))
        defaults.set("newest", forKey: PodcastAutoDownload.directionKey("feed:x"))
        #expect(PodcastAutoDownload.direction("feed:x", defaults: defaults) == .newest)
        #expect(PodcastAutoDownload.isEnabled("feed:x", defaults: defaults))
    }

    private func device(_ cloud: CountingChoiceCloud, now: Double)
        -> (sync: UserChoiceCloudSync, defaults: UserDefaults, suite: String) {
        let suite = "auto-hold-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        var clock = now
        let sync = UserChoiceCloudSync(defaults: defaults, cloud: cloud, syncEnabled: { true },
                                       now: { clock += 1; return clock }, idFormSettled: { true })
        return (sync, defaults, suite)
    }

    @Test("I7 and I8: the direction of A applies on B, on/off and count of B stay, B never unloads, afterwards zero writes")
    func theDirectionTravelsAndNothingElse() {
        let cloud = CountingChoiceCloud()
        let a = device(cloud, now: 10_000)
        let b = device(cloud, now: 20_000)
        defer {
            UserDefaults().removePersistentDomain(forName: a.suite)
            UserDefaults().removePersistentDomain(forName: b.suite)
        }
        let show = "feed:travel"
        // A: on, keeps 10, chooses "in order". B: off, keeps 5, direction newest.
        a.defaults.set(true, forKey: PodcastAutoDownload.flagKey(show))
        a.defaults.set(10, forKey: PodcastAutoDownload.keepKey(show))
        b.defaults.set(false, forKey: PodcastAutoDownload.flagKey(show))
        b.defaults.set(5, forKey: PodcastAutoDownload.keepKey(show))
        #expect(PodcastAutoDownload.direction(show, defaults: b.defaults) == .newest)

        a.defaults.set("inOrder", forKey: PodcastAutoDownload.directionKey(show))
        a.sync.noteScalar(key: PodcastAutoDownload.directionKey(show), value: "inOrder")
        a.sync.reconcile()
        b.sync.reconcile()

        #expect(PodcastAutoDownload.direction(show, defaults: b.defaults) == .inOrder, "the direction of A stands on B")
        #expect(PodcastAutoDownload.isEnabled(show, defaults: b.defaults) == false, "B stays off")
        #expect(PodcastAutoDownload.keep(show, defaults: b.defaults) == 5, "B keeps its own count")
        #expect(PodcastAutoDownload.keep(show, defaults: a.defaults) == 10)
        let document = cloud.storage[UserChoiceCloudSync.blobKey] as? [String: Any] ?? [:]
        #expect(document[PodcastAutoDownload.flagKey(show)] == nil, "on or off does not travel")
        #expect(document[PodcastAutoDownload.keepKey(show)] == nil, "the count does not travel")
        #expect(document[PodcastAutoDownload.directionKey(show)] != nil, "the direction does")

        cloud.writes = 0
        for _ in 0..<2 {
            a.sync.reconcile()
            b.sync.reconcile()
        }
        #expect(cloud.writes == 0, "settled: two more rounds on both devices write nothing")
    }

    @Test("the automation runs only over shows that are on on this device, and on asks only the device values", .needsTheSources)
    func offNeverLoads() throws {
        let helpers = SyncContractFenceTests.stripped(try String(
            contentsOf: SourceTree.root.appendingPathComponent("Sources/Views/Podcasts/PodcastHelpers.swift"), encoding: .utf8))
        let run = try #require(functionBody(of: "static func run(shows: [PodcastShow], router: ItemRouter = .live) async {", in: helpers))
        #expect(run.contains("for show in shows where isEnabled(show.id) {"))
        #expect(run.components(separatedBy: "dm.download(").count - 1 == 1, "one download site, inside the loop over enabled shows")
        let stored = try #require(functionBody(of: "static func storedEnabled(", in: helpers))
        #expect(!stored.contains("irection"), "on or off never reads the direction")
        let general = try #require(functionBody(of: "static func generalEnabled(", in: helpers))
        #expect(!general.contains("generalDirectionKey") && !general.contains("directionKey"),
                "on or off for all shows never reads the travelling direction")
    }
}
#endif
