// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// The held hand-over of a log that follows the account is one shape
/// (`HandOverHold`): the listen log and the notice log take it, and a new
/// log (the listening history) takes it too instead of a third copy.
struct HandOverHoldTests {
    @Test("eine gehaltene Uebergabe behaelt, was waehrenddessen kommt, und gibt es danach in Reihenfolge heraus")
    func aHeldHandOverKeepsAndReleasesInOrder() {
        var hold = HandOverHold<String>()
        #expect(!hold.isHeld)
        let keptWithoutHold = hold.keep("now")
        #expect(!keptWithoutHold, "without a hold an entry waits for nothing")
        #expect(hold.waiting.isEmpty)

        hold.hold(scope: "B", previous: "A")
        #expect(hold.isHeld)
        #expect(hold.target?.scope == "B" && hold.target?.previous == "A")
        let keptFirst = hold.keep("first")
        let keptSecond = hold.keep("second")
        #expect(keptFirst && keptSecond)
        // A second failed try holds for the newer target and keeps the waiting.
        hold.hold(scope: "C", previous: "A")
        #expect(hold.target?.scope == "C")
        #expect(hold.waiting == ["first", "second"])

        let released = hold.handedOver()
        #expect(released == ["first", "second"], "the waiting entries come back out of order or lost")
        #expect(!hold.isHeld)
        #expect(hold.waiting.isEmpty)
        let again = hold.handedOver()
        #expect(again.isEmpty, "a hand-over gives an entry twice")
    }

    /// The two logs that follow the account keep their hold in the one
    /// type; no log keeps a hold of its own.
    @Test("kein Protokoll fuehrt eine eigene gehaltene Uebergabe neben HandOverHold")
    func noLogKeepsAHoldOfItsOwn() {
        var own: [String] = []
        var taking: [String] = []
        for (name, text) in ProjectFileIntegrityTests.sourceTexts(in: ["Sources"]) {
            let code = FetchAnswerTests.squeezed(text)
            if code.contains("var held: (scope: String, previous: String?)") { own.append(name) }
            if code.contains("HandOverHold<") { taking.append(name) }
        }
        #expect(own.isEmpty, "a log keeps its own held hand-over again: \(own)")
        #expect(Set(taking).isSuperset(of: ["PodcastListenLog.swift", "PlaybackNotices.swift"]),
                "a log that follows the account does not take the one hold: \(taking.sorted())")
        #expect(FetchAnswerTests.squeezed("private var held: (scope: String, previous: String?)?")
            .contains("var held: (scope: String, previous: String?)"))
    }
}
#endif
