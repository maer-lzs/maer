// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
import Combine
@testable import Maer

/// A routine's rule: its one spelling as an id, and what it plays.
struct RoutineRuleTests {
    /// The cases live in `Fixtures/Shared/abos/routine-resolve.json`, read by
    /// Swift and Kotlin alike: the spellings of the id, newest heard and
    /// begun, next from where the listener stands, and offline.
    nonisolated static let cases = SharedCases.cases("routine-resolve")

    /// The episodes e1 to eN, pubDate = number; N may be 0.
    private static func episodes(_ input: JSONValue) -> [RoutineRule.Episode] {
        let count = input["episodes"]?["count"]?.int ?? 0
        let played = Set(input["played"]?.strings ?? [])
        let started = Set(input["started"]?.strings ?? [])
        let local = Set(input["local"]?.strings ?? [])
        guard count > 0 else { return [] }
        return (1...count).map { number in
            let guid = "e\(number)"
            return .init(guid: guid, pubDate: Double(number), isPlayed: played.contains(guid),
                         isStarted: started.contains(guid), isDownloaded: local.contains(guid))
        }
    }

    @Test("gemeinsame Faelle: routine-resolve traegt siebenundzwanzig Faelle")
    func casesLoaded() {
        #expect(Self.cases.count == 27)
    }

    @Test("gemeinsame Faelle: eine Regel antwortet je Fall wie die Datei sagt", arguments: cases)
    func eachCase(_ c: SharedCase) throws {
        let input = try c.value("input")
        switch c.ask {
        case "id":
            let id = try #require(input.string)
            #expect(RoutineRule(id: id)?.id == c["expect"]?.string, "\(c.slug)")
        case "resolve":
            let kind: RoutineRule.Kind = input["rule"]?.string == "newest"
                ? .newest : .next(count: try #require(input["count"]?.int))
            let rule = try #require(RoutineRule(kind: kind, feedKey: "9f2c"), "\(c.slug)")
            let outcome = rule.resolve(Self.episodes(input), online: try #require(input["online"]?.bool))
            switch outcome {
            case .play(let guids): #expect(guids == c["expect"]?.strings, "\(c.slug)")
            case .absent(let absence): #expect("\(absence)" == c["expect"]?.string, "\(c.slug)")
            }
        default:
            Issue.record("\(c.slug): unknown ask \(c.ask)")
        }
    }

    /// Next picks after the listener's place, so episodes before it that
    /// are still unheard do not count, and the line says so.
    @Test("naechste ohne Wahl heisst ab dem Stand nichts Ungehoertes, auch wenn davor ungehoerte stehen")
    func nothingNextMeansNothingFromThePlace() throws {
        let rule = try #require(RoutineRule(kind: .next(count: 1), feedKey: "aaaa"))
        let episodes = (1...3).map { RoutineRule.Episode(guid: "e\($0)", pubDate: Double($0), isPlayed: $0 == 3,
                                                         isStarted: false, isDownloaded: false) }
        #expect(rule.resolve(episodes, online: true) == .absent(.nothingNext))
        #expect(RoutineRule.Absence.nothingNext.rawValue == "no unheard episode from where the listener stands")
    }

    @Test("eine Regel je Sendung: die Routine findet die Regel ihrer Sendung, nicht die einer anderen")
    func oneRulePerShow() {
        let ids = ["rss:a:1", "rule:newest:aaaa", "rule:next:2:bbbb", "rule:next:4:cccc"]
        #expect(RoutineRule.ofShow("aaaa", in: ids)?.kind == .newest)
        #expect(RoutineRule.ofShow("bbbb", in: ids)?.kind == .next(count: 2))
        #expect(RoutineRule.ofShow("cccc", in: ids) == nil, "a form this build does not read is no rule")
        #expect(RoutineRule.ofShow("dddd", in: ids) == nil)
    }

    @Test("die Regel baut nur Kennungen, die sie selbst wieder liest")
    func everyRuleReadsBack() {
        #expect(RoutineRule(kind: .next(count: 0), feedKey: "aaaa") == nil)
        #expect(RoutineRule(kind: .next(count: 4), feedKey: "aaaa") == nil)
        #expect(RoutineRule(kind: .newest, feedKey: "") == nil)
        #expect(RoutineRule(kind: .newest, feedKey: "a:b") == nil, "a colon would split the key")
        for kind in [RoutineRule.Kind.newest] + RoutineRule.counts.map(RoutineRule.Kind.next(count:)) {
            let rule = RoutineRule(kind: kind, feedKey: "aaaa")
            #expect(rule.flatMap { RoutineRule(id: $0.id) } == rule, "\(kind)")
            #expect(rule.map { ItemNamespace.isRoutineRule($0.id) } == true)
            #expect(rule.map { ItemNamespace.of($0.id) } == "rule:")
        }
    }

    /// The carry witnesses write their rules out so they run against a build
    /// without routines; here they must be rules in their one spelling.
    @Test("die Regeln der Traegerzeugen sind Regeln in ihrer einen Schreibweise")
    func theCarriedIdsAreRules() {
        for id in RoutineCarryTests.ruleIds {
            #expect(RoutineRule(id: id)?.id == id, "\(id)")
        }
    }

    /// The order "next" reads is the auto-download's own, with the judgement
    /// handed in: no second function that would answer "where does the
    /// listener stand" differently.
    @Test("naechste fragt PodcastAutoDownloadRules.nextInOrder, keine zweite Reihenfolge", .needsTheSources)
    func nextAsksTheOneOrder() throws {
        let code = SyncContractFenceTests.stripped(try String(
            contentsOf: SourceTree.root.appendingPathComponent("Sources/Models/RoutineRule.swift"), encoding: .utf8))
        #expect(code.components(separatedBy: "PodcastAutoDownloadRules.nextInOrder(").count - 1 == 1)
        for own in ["anchorIndex", "runGap", ".sorted"] {
            #expect(!code.contains(own), "the routine builds an order of its own: \(own)")
        }
    }

    /// A rule is a namespace this build knows, never a source: the seam calls
    /// it a rule, the page shows its line, and nothing asks a server.
    @Test("eine Regel ist bekannt und erreicht keine Quelle, die Naht nennt sie Regel")
    func aRuleIsKnownAndReachesNoSource() {
        let id = "rule:newest:aaaa"
        #expect(ItemNamespace.isKnown(id))
        #expect(!ItemNamespace.mayReachLibraryServer(id))
        #expect(SyncCarried.resolve(itemId: id, carried: nil, known: nil, sourceConfigured: false).reason == .routineRule)
        #expect(SyncCarried.resolve(itemId: id, carried: nil, known: nil, sourceConfigured: true).reason == .routineRule)
    }

    /// The menu offers every rule once, and a rule over a show the routine
    /// holds a rule for clashes, the same rule among them.
    @Test("eine Sendung bietet jede Regel einmal an, und je Sendung steht eine Regel in der Routine")
    func aShowOffersEachRuleAndHoldsOne() {
        #expect(RoutineRule.offered(feedKey: "aaaa").map(\.id)
                == ["rule:newest:aaaa", "rule:next:aaaa", "rule:next:2:aaaa", "rule:next:3:aaaa"])
        #expect(RoutineRule.offered(feedKey: "a:b").isEmpty, "no feed key, no rule")
        let held = ["rss:x:1", "rule:newest:aaaa"]
        #expect(RoutineRule.clashes("rule:newest:aaaa", in: held))
        #expect(RoutineRule.clashes("rule:next:3:aaaa", in: held))
        #expect(!RoutineRule.clashes("rule:next:bbbb", in: held))
        #expect(!RoutineRule.clashes("rss:x:1", in: held), "a title is no rule")
    }
}

/// Adding keeps one rule per show; two devices can still each add one to
/// the same list. The merge keeps the newer side's and settles there.
@MainActor
@Suite(.serialized)
struct RoutineMergeTests {
    private final class RecordingCarrier: PlaylistCarrier {
        var name: String { "recording" }
        var snapshot = MaerPlaylistMerge.Snapshot()
        var stores = 0
        func held() -> MaerPlaylistMerge.Snapshot { snapshot }
        func store(_ snapshot: MaerPlaylistMerge.Snapshot) {
            self.snapshot = snapshot
            stores += 1
        }
        func start(onChange: @escaping @MainActor () -> Void) {}
        func stop() {}
        func refresh(by caller: String) async {}
    }

    @Test("zwei Geraete mit je einer anderen Regel derselben Sendung schwingen auf eine ein, die der neueren Seite, danach ueber fuenf Runden kein Schrieb")
    func twoRulesOfOneShowSettleOnOne() throws {
        let restore = SyncSwitchProbe.armOn()
        defer { restore() }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("routine-merge-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let carrier = RecordingCarrier()
        func device(_ name: String) -> (store: MaerPlaylists, runner: MaerPlaylistCloudSync) {
            let store = MaerPlaylists(database: MaerDatabase(path: directory.appendingPathComponent("\(name).sqlite").path))
            return (store, MaerPlaylistCloudSync(carrier: carrier, playlists: store, itemIdMap: { $0 },
                                                 deviceName: { name }, idFormSettled: { true }))
        }
        let a = device("Geraet-A")
        let b = device("Geraet-B")
        let list = a.store.create(name: "Morgens")
        _ = a.store.add(itemId: "rss:f:e1", to: list.id)
        a.runner.reconcile()
        b.runner.reconcile()
        #expect(b.store.playlist(id: list.id) != nil, "the precondition: both devices hold the list")

        // Each device adds a rule of the same show before the next round; B's is the newer.
        #expect(a.store.add(itemId: "rule:newest:aaaa", to: list.id) == .added)
        _ = a.store.add(itemId: "rule:next:bbbb", to: list.id)
        #expect(b.store.add(itemId: "rule:next:aaaa", to: list.id) == .added)
        for _ in 0..<3 {
            a.runner.reconcile()
            b.runner.reconcile()
        }
        let expected = ["rss:f:e1", "rule:next:aaaa", "rule:next:bbbb"]
        #expect(a.store.playlist(id: list.id)?.itemIds == expected, "one rule of the show, the newer side's; another show's rule stays")
        #expect(b.store.playlist(id: list.id)?.itemIds == expected)
        #expect(carrier.snapshot.lists[list.id]?.itemIds == expected)

        final class Counter { var writes = 0 }
        let local = Counter()
        let watching = [a.store.objectWillChange.sink { local.writes += 1 },
                        b.store.objectWillChange.sink { local.writes += 1 }]
        let settled = carrier.stores
        for _ in 0..<5 {
            a.runner.reconcile()
            b.runner.reconcile()
        }
        #expect(carrier.stores == settled, "settled lists are no reason to write")
        #expect(local.writes == 0, "no write to either store: \(local.writes)")
        withExtendedLifetime((a.runner, b.runner, watching)) {}
    }
}
#endif
