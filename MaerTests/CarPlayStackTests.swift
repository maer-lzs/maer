// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Foundation
import Testing
@testable import Maer

/// The car's stack of templates: the player lies in it at most once, no
/// template goes beyond the limit, and every change ends in a closure.
struct CarPlayStackTests {

    @Test("der Player zuoberst bleibt, wo er ist")
    func thePlayerOnTopStays() {
        #expect(CarPlayLayout.playerMove(playerOnTop: true, playerIndex: 3, depth: 4) == .stay)
        #expect(CarPlayLayout.playerMove(playerOnTop: true, playerIndex: nil, depth: 2) == .stay,
                "the system shows the player without the stack naming it")
        #expect(CarPlayLayout.playerMove(playerOnTop: false, playerIndex: 3, depth: 4) == .stay)
    }

    @Test("liegt der Player unter einer Liste, geht das Auto zu ihm zurueck und legt ihn nicht neu auf")
    func thePlayerUnderAListIsGoneBackTo() {
        #expect(CarPlayLayout.playerMove(playerOnTop: false, playerIndex: 3, depth: 5) == .back)
        #expect(CarPlayLayout.playerMove(playerOnTop: false, playerIndex: 1, depth: 3) == .back)
    }

    @Test("liegt der Player nicht im Stapel, wird er aufgelegt, solange Platz ist")
    func thePlayerOutsideTheStackIsLaidOn() {
        #expect(CarPlayLayout.playerMove(playerOnTop: false, playerIndex: nil, depth: 1) == .push)
        #expect(CarPlayLayout.playerMove(playerOnTop: false, playerIndex: nil, depth: CarPlayLayout.stackLimit - 1) == .push)
    }

    @Test("am Rand des Stapels wird nichts mehr aufgelegt, weder der Player noch eine Liste")
    func atTheLimitNothingIsLaidOn() {
        #expect(CarPlayLayout.stackLimit == 5, "the tab bar, two levels, the player and its list")
        #expect(CarPlayLayout.playerMove(playerOnTop: false, playerIndex: nil, depth: CarPlayLayout.stackLimit) == .full)
        #expect(CarPlayLayout.mayPush(depth: CarPlayLayout.stackLimit - 1))
        #expect(!CarPlayLayout.mayPush(depth: CarPlayLayout.stackLimit))
        #expect(!CarPlayLayout.mayPush(depth: CarPlayLayout.stackLimit + 1))
    }

    /// The rule reads the stack as it stands, not the way it came to be.
    @Test("drei Wege zu einem Stapel: eine zweite Liste des Players, eine spaete Seite ueber dem Player, eine verirrte Seite")
    func threeWaysToAStack() {
        // The tab bar, two levels, the player and its list: a second tap
        // on the player's list button finds the stack full.
        #expect(!CarPlayLayout.mayPush(depth: 5), "a second list of the player goes on as a sixth level")
        // A page that waited for its rows lies over the player, wherever
        // the player stands: the next playing row goes back to it.
        for (index, depth) in [(1, 2 + 1), (2, 4), (3, 5), (1, 5)] {
            #expect(CarPlayLayout.playerMove(playerOnTop: false, playerIndex: index, depth: depth) == .back,
                    "the player at \(index) of \(depth) is laid on again")
        }
        // A stray page without the player is one level more: the player
        // still goes on while there is room, and not beyond it.
        #expect(CarPlayLayout.playerMove(playerOnTop: false, playerIndex: nil, depth: 4) == .push)
        #expect(CarPlayLayout.playerMove(playerOnTop: false, playerIndex: nil, depth: 5) == .full)
        #expect(CarPlayLayout.playerMove(playerOnTop: false, playerIndex: nil, depth: 6) == .full)
    }

    @Test("kein Wechsel des Stapels laeuft ohne Abschluss, und jedes Auflegen fragt vorher die Regel", .needsTheSources)
    func noChangeOfTheStackRunsWithoutAClosure() throws {
        let root = SourceTree.root.appendingPathComponent("Sources")
        let changes = ["pushTemplate(", "pop(to:", "popToTemplate(", "popTemplate(", "popToRootTemplate(",
                       "setRootTemplate(", "presentTemplate(", "dismissTemplate("]
        var seen = 0
        var bare: [String] = []
        for file in SourceTree.files(under: root) where file.pathExtension == "swift" {
            let text = try String(contentsOf: file, encoding: .utf8)
            for (number, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                let code = line.trimmingCharacters(in: .whitespaces)
                guard !code.hasPrefix("//"), changes.contains(where: { code.contains("." + $0) }) else { continue }
                seen += 1
                if !code.contains("completion: Self.settled(") { bare.append("\(file.lastPathComponent):\(number + 1)") }
            }
        }
        #expect(seen == 4, "the stack changes in \(seen) places: the root, a list, the player laid on, back to the player")
        #expect(bare.isEmpty, "a change of the stack without the closure: \(bare)")
        let delegate = try String(contentsOf: root.appendingPathComponent("CarPlay/CarPlaySceneDelegate.swift"), encoding: .utf8)
        let push = try #require(functionBody(of: "private func push(_ template: CPTemplate)", in: delegate))
        let asked = try #require(push.range(of: "guard CarPlayLayout.mayPush(depth: depth) else {"))
        let laid = try #require(push.range(of: "interfaceController.pushTemplate(template"))
        #expect(asked.lowerBound < laid.lowerBound, "the list is laid on before the rule is asked")
        let show = try #require(functionBody(of: "private func showNowPlaying()", in: delegate))
        #expect(show.contains("CarPlayLayout.playerMove(playerOnTop:"), "the player is shown past the rule")
        #expect(delegate.components(separatedBy: "pushTemplate(nowPlaying").count - 1 == 1, "the player is laid on in another place")
    }

    @Test("Gleichheit zweier Bezuege: keiner ist kein Treffer")
    @MainActor
    func theSameObject() {
        let one = NSObject(), other = NSObject()
        #expect(CarPlaySceneDelegate.isSame(one, one))
        #expect(!CarPlaySceneDelegate.isSame(one, other))
        #expect(!CarPlaySceneDelegate.isSame(nil, one) && !CarPlaySceneDelegate.isSame(one, nil) && !CarPlaySceneDelegate.isSame(nil, nil))
    }

    /// The first build after a connect is held and ends at a disconnect;
    /// after its waits it sets nothing on a scene that is gone, and a
    /// second tap on Up Next lays no second list over the first.
    @Test("Trennen waehrend des ersten Aufbaus setzt nichts mehr; zweimal Als Naechstes legt eine Liste", .needsTheSources)
    func aDisconnectEndsTheFirstBuild() throws {
        let delegate = try FetchAnswerTests.squeezedSource("Sources/CarPlay/CarPlaySceneDelegate.swift")
        #expect(delegate.contains("connectTask?.cancel() connectTask = Task { await self.prepare() guard Self.isSame(self.interfaceController, interfaceController) else {"),
                "the first build is not held, or does not ask after it prepared")
        #expect(delegate.contains("signals.removeAll() rateSignal = nil connectTask?.cancel() connectTask = nil"),
                "a disconnect leaves the first build running")
        #expect(delegate.contains("guard interfaceController != nil, !Task.isCancelled else { return } let templates = layout.tabs.compactMap { roots[$0] }"),
                "the rebuild sets the tab bar on a scene that is gone")
        #expect(delegate.contains("guard !upNextPushing, !Self.isSame(interfaceController?.topTemplate, upNextList) else { return }"),
                "a second tap lays a second Up Next list")
    }
}
#endif
