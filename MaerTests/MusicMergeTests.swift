// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// The rules that make one list out of two music servers: a zipper with an
/// offset per source, recency on one clock or rank by rank, and a shuffle
/// pool with fill-up. Nothing is merged by name.
struct MusicMergeTests {
    typealias S = MusicMerge.Stream<String>

    static func streams(_ lists: [[String]], exhausted: Bool = true) -> [S] {
        lists.map { S(buffer: $0, offset: $0.count, exhausted: exhausted) }
    }

    // MARK: Zipper

    @Test("Reissverschluss nach Namen: beide Quellen in einer Ordnung, keine Zusammenfuehrung")
    func zipperByName() {
        var s = Self.streams([["Abba", "Cure", "Eno"], ["Björk", "Cure", "Dylan"]])
        let page = MusicMerge.take(10, from: &s, inOrder: MusicMerge.nameOrder)
        #expect(page.items == ["Abba", "Björk", "Cure", "Cure", "Dylan", "Eno"],
                "gleiche Namen bleiben zwei Eintraege, die erste Quelle zuerst")
        #expect(page.needs.isEmpty)
    }

    @Test("ein leerer Puffer einer nicht erschoepften Quelle haelt die Seite an")
    func anEmptyBufferWaits() {
        var s = [S(buffer: ["Abba", "Cure"], offset: 2, exhausted: false), S(buffer: ["Björk"], offset: 1, exhausted: false)]
        let page = MusicMerge.take(10, from: &s, inOrder: MusicMerge.nameOrder)
        #expect(page.items == ["Abba", "Björk"], "nach Björk koennte die zweite Quelle vor Cure liegen")
        #expect(page.needs == [1])
        #expect(s[0].buffer == ["Cure"], "was nicht ausgegeben ist, bleibt im Puffer")
    }

    @Test("Blaettern mit einem Versatz je Quelle: jede Quelle wird an ihrer eigenen Stelle gefragt")
    func pagingWithAnOffsetPerSource() async {
        let a = (1...7).map { String(format: "a%02d", $0) }
        let b = (1...3).map { String(format: "b%02d", $0) }
        var asked: [(Int, Int)] = []
        var s = [S(), S()]
        func fetch(_ source: Int, _ offset: Int, _ size: Int) async throws -> [String] {
            asked.append((source, offset))
            let list = source == 0 ? a : b
            return Array(list.dropFirst(offset).prefix(size))
        }
        let first = await MusicMerge.page(4, streams: &s, inOrder: <, fetch: fetch)
        let second = await MusicMerge.page(4, streams: &s, inOrder: <, fetch: fetch)
        let third = await MusicMerge.page(4, streams: &s, inOrder: <, fetch: fetch)
        #expect(first.items == ["a01", "a02", "a03", "a04"])
        #expect(second.items == ["a05", "a06", "a07", "b01"])
        #expect(third.items == ["b02", "b03"])
        #expect((first.items + second.items + third.items).count == 10, "nichts doppelt, nichts verloren")
        #expect(asked.map(\.0) == [0, 1, 0], "b wird nur einmal gefragt, a an seinem eigenen Versatz nach")
        #expect(asked.map(\.1) == [0, 0, 4])
    }

    @Test("faellt eine Quelle aus, blaettert die andere weiter, und der Ausfall wird gemeldet")
    func aFailingSourceStopsOnlyItself() async {
        struct Down: Error {}
        var s = [S(), S()]
        let page = await MusicMerge.page(3, streams: &s, inOrder: <) { source, offset, size in
            if source == 1 { throw Down() }
            return Array(["x1", "x2", "x3", "x4"].dropFirst(offset).prefix(size))
        }
        #expect(page.items == ["x1", "x2", "x3"])
        #expect(page.failed == [1])
    }

    @Test("Namensordnung: ohne Namen ans Ende, Zahlen wie Menschen sie lesen")
    func nameOrder() {
        #expect(MusicMerge.nameOrder("Track 2", "Track 10"))
        #expect(MusicMerge.nameOrder("a", nil))
        #expect(!MusicMerge.nameOrder(nil, "a"))
        #expect(!MusicMerge.nameOrder(nil, nil))
    }

    // MARK: Recency

    struct Album: Equatable { let id: String; let played: Double? }

    @Test("zuletzt gespielt: eine Uhr, wenn jedes Album seinen Zeitpunkt traegt")
    func oneClock() {
        let a = [Album(id: "a1", played: 50), Album(id: "a2", played: 10)]
        let b = [Album(id: "b1", played: 40), Album(id: "b2", played: 30)]
        #expect(MusicMerge.order([a, b], stamp: \.played) == .clock)
        #expect(MusicMerge.byRecency([a, b], stamp: \.played).map(\.id) == ["a1", "b1", "b2", "a2"])
    }

    @Test("fehlt einer Seite die Uhr, dann Rang um Rang, entschieden an den Daten")
    func rankByRankWithoutAClock() {
        let a = [Album(id: "a1", played: 50), Album(id: "a2", played: 10), Album(id: "a3", played: 5)]
        let b = [Album(id: "b1", played: nil)]
        #expect(MusicMerge.order([a, b], stamp: \.played) == .rankByRank)
        #expect(MusicMerge.byRecency([a, b], stamp: \.played).map(\.id) == ["a1", "b1", "a2", "a3"],
                "der Rest der laengeren Liste in ihrer eigenen Ordnung")
        // Every list has SOME moment, one item has none: still no clock. A
        // list sorted on a clock it only partly has would put that item last.
        let partial = [Album(id: "c1", played: 40), Album(id: "c2", played: nil)]
        #expect(MusicMerge.order([a, partial], stamp: \.played) == .rankByRank)
        #expect(MusicMerge.byRecency([a, partial], stamp: \.played).map(\.id) == ["a1", "c1", "a2", "c2", "a3"])
    }

    @Test("gleiche Zeitpunkte behalten die Ordnung der Quelle")
    func equalMomentsKeepSourceOrder() {
        let a = [Album(id: "a1", played: 7)]
        let b = [Album(id: "b1", played: 7)]
        #expect(MusicMerge.byRecency([a, b], stamp: \.played).map(\.id) == ["a1", "b1"])
        #expect(MusicMerge.byRecency([b, a], stamp: \.played).map(\.id) == ["b1", "a1"])
    }

    struct Counted: Equatable { let id: String; let plays: Int? }

    @Test("meistgespielt: nach Zahl, wenn jedes Album eine traegt, sonst Rang um Rang")
    func byPlayCount() {
        let a = [Counted(id: "a1", plays: 9), Counted(id: "a2", plays: 1)]
        let b = [Counted(id: "b1", plays: 5)]
        #expect(MusicMerge.byPlayCount([a, b], count: \.plays).map(\.id) == ["a1", "b1", "a2"])
        let none = [Counted(id: "c1", plays: nil)]
        #expect(MusicMerge.byPlayCount([a, none], count: \.plays).map(\.id) == ["a1", "c1", "a2"])
    }

    // MARK: Shuffle

    @Test("Zufall: gleiche Anteile, und was eine Quelle nicht fuellt, fuellt die andere")
    func sharedPoolFills() {
        var rng = SystemRandomNumberGenerator()
        let big = (1...100).map { "a\($0)" }
        let small = ["b1", "b2", "b3"]
        let even = MusicMerge.sharedPool([big, (1...100).map { "b\($0)" }], limit: 10, using: &rng)
        #expect(even.count == 10 && even.filter { $0.hasPrefix("a") }.count == 5)
        let filled = MusicMerge.sharedPool([big, small], limit: 10, using: &rng)
        #expect(filled.count == 10, "die kleine Bibliothek laesst keine halbe Liste")
        #expect(Set(filled.filter { $0.hasPrefix("b") }) == Set(small))
        let odd = MusicMerge.sharedPool([big, big.map { "c" + $0 }], limit: 5, using: &rng)
        #expect(odd.count == 5)
        let empty = MusicMerge.sharedPool([[String](), small], limit: 10, using: &rng)
        #expect(Set(empty) == Set(small), "eine leere Quelle nimmt nichts weg")
    }

    // MARK: One source

    @Test("mit EINER Liste gibt jede Regel sie unveraendert zurueck")
    func oneListIsUnchanged() async {
        let list = ["z", "a", "m"]
        var s = [S(buffer: list, offset: 3, exhausted: true)]
        #expect(MusicMerge.take(10, from: &s, inOrder: MusicMerge.nameOrder).items == list,
                "die Ordnung des Servers bleibt, auch wenn sie nicht nach Namen ist")
        let albums = [Album(id: "x", played: 1), Album(id: "y", played: 9)]
        #expect(MusicMerge.byRecency([albums], stamp: \.played) == albums)
        #expect(MusicMerge.rankByRank([list]) == list)
        var rng = SystemRandomNumberGenerator()
        #expect(MusicMerge.sharedPool([list], limit: 10, using: &rng) == list,
                "eine Quelle wird nicht neu gemischt, sie kommt schon zufaellig")
    }
}
#endif
