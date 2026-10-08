// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// A value of the start page's music rows that landed is replaced by no
/// later empty one: no answer keeps it, an older pass's late answer does
/// not replace a newer one, and the two halves of "Recently Played" keep
/// each other.
@MainActor
struct LateMusicValuesTests {
    private func items(_ ids: String...) -> [LibraryItem] {
        ids.map { LibraryItem(id: $0, media: nil, addedAt: nil) }
    }

    @Test("die Regel: nur eine Antwort ersetzt, und nie die eines neueren Durchgangs")
    func theRule() {
        #expect(LandedValue.replaces(answered: true, pass: 1, landedPass: 0))
        #expect(LandedValue.replaces(answered: true, pass: 2, landedPass: 2), "the late answer of the same pass")
        #expect(!LandedValue.replaces(answered: false, pass: 3, landedPass: 1), "no answer replaced what landed")
        #expect(!LandedValue.replaces(answered: true, pass: 1, landedPass: 2), "an older pass replaced a newer one")
    }

    @Test("keine Antwort laesst stehen, was gelandet ist: Regal, Neueste und Fortschritt")
    func noAnswerKeepsWhatLanded() {
        let values = LateMusicValues()
        let first = values.beginPass()
        values.setShelf(items("a"), pass: first)
        values.setNewAlbums(items("n"), pass: first)
        values.setProgress(["a": BookProgress(fraction: 0.5, isFinished: false, lastUpdate: 1, currentTime: 10)], pass: first)
        let second = values.beginPass()
        values.setShelf(nil, pass: second)
        values.setNewAlbums(nil, pass: second)
        values.setProgress(nil, pass: second)
        #expect(values.recentAlbums.map(\.id) == ["a"], "a pass without an answer emptied the row")
        #expect(values.newAlbums.map(\.id) == ["n"], "a pass without an answer emptied the newest albums")
        #expect(values.progress.keys.sorted() == ["a"], "a pass without an answer emptied the progress")
    }

    @Test("eine echte leere Antwort leert, eine spaete Antwort eines aelteren Durchgangs ersetzt keine neuere")
    func anEmptyAnswerEmptiesAnOlderOneDoesNotReplace() {
        let values = LateMusicValues()
        let first = values.beginPass()
        let second = values.beginPass()
        values.setShelf(items("b"), pass: second)
        values.setShelf(items("a"), pass: first)
        #expect(values.recentAlbums.map(\.id) == ["b"], "the late answer of the older pass replaced the newer one")
        let third = values.beginPass()
        values.setShelf([], pass: third)
        #expect(values.recentAlbums.isEmpty, "a real empty answer did not empty the row")
    }

    @Test("Zuletzt gespielt in zwei Haelften: ein spaetes Regal laesst die angefangenen Alben stehen und umgekehrt")
    func theTwoHalvesKeepEachOther() {
        let values = LateMusicValues()
        values.setStartedAlbums(items("s"), pass: values.beginPass())
        let pass = values.beginPass()
        values.setShelf(items("a", "s"), pass: pass)
        #expect(values.recentAlbums.map(\.id) == ["a", "s"], "the shelf dropped a started album or doubled it")
        values.addRecentAlbums(items("t"))
        #expect(values.recentAlbums.map(\.id) == ["a", "s", "t"])
        values.setShelf(items("c"), pass: values.beginPass())
        #expect(values.recentAlbums.map(\.id) == ["c", "s", "t"], "a later shelf dropped the started albums")
    }

    @Test("die angefangenen Alben tragen ihren Durchgang: ein aelterer, der zuletzt endet, setzt sie nicht zurueck")
    func startedAlbumsCarryTheirPass() {
        let values = LateMusicValues()
        let first = values.beginPass(), second = values.beginPass()
        values.setStartedAlbums(items("new"), pass: second)
        values.setStartedAlbums(items("old"), pass: first)
        #expect(values.recentAlbums.map(\.id) == ["new"], "the older pass set the started albums back")
        // A later pass with nothing started empties the half: it is an answer.
        values.setStartedAlbums([], pass: values.beginPass())
        #expect(values.recentAlbums.isEmpty, "nothing started did not empty the half")
    }

    @Test("die Startseite reicht keine fehlgeschlagene Musikquelle als leere Reihe weiter, und jede Antwort traegt ihren Durchgang", .needsTheSources)
    func theStartPageHandsInAnswers() throws {
        let home = SyncContractFenceTests.stripped(try String(
            contentsOf: SourceTree.root.appendingPathComponent("Sources/Views/HomeView.swift"), encoding: .utf8))
        #expect(home.contains("lateMusic.beginPass()"), "the fence read the start page")
        #expect(Self.failuresAsEmpty(in: home) == 0, "a failed music source stands in for an empty row")
        #expect(Self.settersWithoutPass(in: home) == 0, "an answer goes in without its pass")
        // Calibration: the forms as they stood.
        #expect(Self.failuresAsEmpty(in: "(try? await musicProvider.fetchAllProgress()) ?? [:]") == 1)
        #expect(Self.settersWithoutPass(in: "LateMusicValues.shared.setProgress(late)\nlateMusic.setShelf(x, pass: p)") == 1)
        #expect(Self.settersWithoutPass(in: "lateMusic.setStartedAlbums(startedAlbums)") == 1)
    }

    nonisolated static func failuresAsEmpty(in code: String) -> Int {
        code.matches(of: #/try\?\s*await\s+musicProvider\./#).count
    }

    nonisolated static func settersWithoutPass(in code: String) -> Int {
        code.split(separator: "\n").filter { line in
            line.contains(".setProgress(") || line.contains(".setNewAlbums(") || line.contains(".setShelf(")
                || line.contains(".setStartedAlbums(")
        }.filter { !$0.contains("pass:") }.count
    }
}
#endif
