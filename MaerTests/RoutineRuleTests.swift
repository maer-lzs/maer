// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
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

    /// Until a routine plays, this build reads a rule as a build without
    /// routines does: an unknown source, dimmed and skipped.
    @Test("bis eine Routine spielt, liest dieser Stand eine Regel wie ein Stand ohne Routinen")
    func aRuleIsNotYetAKnownSource() {
        #expect(!ItemNamespace.isKnown("rule:newest:aaaa"))
        #expect(!ItemNamespace.mayReachLibraryServer("rule:newest:aaaa"))
    }
}
#endif
