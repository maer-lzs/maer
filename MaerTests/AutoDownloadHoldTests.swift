// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// Die Automatik haelt je Sendung eine gewaehlte Anzahl: was ueber der Anzahl
/// liegt, geht am weitesten von der Richtung zuerst, nie eine angefangene
/// oder die spielende. Die Richtung reist, Ein/Aus und Anzahl bleiben am
/// Geraet, und der Umzug vom alten einen Wert schreibt nichts.
@MainActor
struct AutoDownloadHoldTests {
    typealias Rules = PodcastAutoDownloadRules

    /// Episodes e1 (oldest) to e10 (newest), pubDate = number.
    private func owned(_ numbers: [Int], protected: Set<Int> = []) -> [Rules.Owned] {
        numbers.map { Rules.Owned(id: "e\($0)", pubDate: Double($0), isProtected: protected.contains($0)) }
    }

    @Test("I2: Neueste von 5 auf 1: die neueste bleibt, die vier aeltesten gehen")
    func newestFiveToOne() {
        let own = owned([6, 7, 8, 9, 10])
        let hold = Rules.hold(wanted: ["e10", "e9", "e8", "e7", "e6"], isDownloaded: { _ in true },
                              own: own, direction: .newest, limit: 1)
        #expect(hold.drop == ["e6", "e7", "e8", "e9"], "oldest first")
        #expect(hold.fetch.isEmpty)
    }

    @Test("I2: Der Reihe nach von 5 auf 1: die naechste zum Hoeren bleibt, die vier neuesten gehen")
    func inOrderFiveToOne() {
        let own = owned([6, 7, 8, 9, 10])
        let hold = Rules.hold(wanted: ["e6", "e7", "e8", "e9", "e10"], isDownloaded: { _ in true },
                              own: own, direction: .inOrder, limit: 1)
        #expect(hold.drop == ["e10", "e9", "e8", "e7"], "farthest from where the listener stands first")
        #expect(!hold.drop.contains("e6"), "the next episode to hear stays")
    }

    @Test("I2: eine angefangene Folge geht nie wegen der Anzahl, auch als aelteste bei Neueste")
    func aBegunEpisodeStays() {
        let own = owned([2, 8, 9], protected: [2])
        let hold = Rules.hold(wanted: ["e9", "e8"], isDownloaded: { _ in true },
                              own: own, direction: .newest, limit: 1)
        #expect(!hold.drop.contains("e2"), "begun: never dropped")
        #expect(hold.drop == ["e8"], "the unprotected one outside the target goes")
    }

    @Test("I2: die Standby-Folge geht bei N = 1 und Neueste nicht, auch wenn sie die aelteste eigene ist; die neue wartet")
    func theStandbyEpisodeStays() {
        // e1 is the standby pointer (protected), the newest e5 is wanted.
        let own = owned([1], protected: [1])
        let hold = Rules.hold(wanted: ["e5"], isDownloaded: { $0 == "e1" },
                              own: own, direction: .newest, limit: 1)
        #expect(hold.drop.isEmpty, "the playing episode is never dropped")
        #expect(hold.fetch.isEmpty, "the new one waits while the count is full of protected ones")
    }

    @Test("I2: Nachrichten mit 1: die gehoerte gestrige geht, die neue kommt; von Hand geladene stehen nicht in der Rechnung")
    func aNewsShowKeepsOnlyTheNewest() {
        // e3 heard (not wanted any more), e4 new; e2 downloaded by hand is
        // not own and therefore not in `own`.
        let hold = Rules.hold(wanted: ["e4"], isDownloaded: { $0 == "e3" || $0 == "e2" },
                              own: owned([3]), direction: .newest, limit: 1)
        #expect(hold.drop == ["e3"])
        #expect(hold.fetch == ["e4"])
        #expect(!hold.drop.contains("e2"), "a download by hand never goes")
    }

    @Test("I2: unter der Anzahl wird aufgefuellt, ueber nichts geraeumt")
    func underTheCountFills() {
        let hold = Rules.hold(wanted: ["e10", "e9", "e8"], isDownloaded: { $0 == "e10" },
                              own: owned([10]), direction: .newest, limit: 3)
        #expect(hold.fetch == ["e9", "e8"])
        #expect(hold.drop.isEmpty)
    }

    // MARK: - I6, I7, I8: the values and where they live

    private func suite() -> (defaults: UserDefaults, name: String) {
        let name = "auto-hold-\(UUID().uuidString)"
        return (UserDefaults(suiteName: name)!, name)
    }

    private func snapshot(_ defaults: UserDefaults, _ name: String) -> NSDictionary {
        (defaults.persistentDomain(forName: name) ?? [:]) as NSDictionary
    }

    @Test("I6: der alte eine Wert wird beim Lesen zerlegt, jede Form behaelt ihre Wirkung, und nichts wird geschrieben")
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

    @Test("I6: ein neuer Wert gewinnt ueber den alten, eine reisende Richtung schlaegt den alten Wert des Geraets")
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
                                       now: { clock += 1; return clock })
        return (sync, defaults, suite)
    }

    @Test("I7 und I8: die Richtung von A steht auf B, Ein/Aus und Anzahl von B bleiben, B laedt aus nie, danach null Schreibvorgaenge")
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

        #expect(PodcastAutoDownload.direction(show, defaults: b.defaults) == .inOrder, "I7: the direction of A stands on B")
        #expect(PodcastAutoDownload.isEnabled(show, defaults: b.defaults) == false, "I8: B stays off")
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

    @Test("I8: die Automatik laeuft nur ueber Sendungen, die auf diesem Geraet an sind, und an fragt nur die Geraete-Werte", .needsTheSources)
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
