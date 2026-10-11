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

    /// A held target typed as the tuple of the hold, under any name.
    /// Parameter lists (`hold(scope:previous:)`, `follow(owner scope:...)`)
    /// are no type annotation and do not count.
    nonisolated static func ownHolds(in code: String) -> Int {
        code.matches(of: #/:\s*\(\s*scope:\s*String\s*,\s*previous:\s*String\?\s*\)/#).count
    }

    /// The logs that follow the account keep their hold in the one type;
    /// no log keeps a hold of its own, whatever it calls it.
    @Test("kein Protokoll fuehrt eine eigene gehaltene Uebergabe neben HandOverHold")
    func noLogKeepsAHoldOfItsOwn() {
        var own: [String] = []
        var taking: [String] = []
        for (name, text) in ProjectFileIntegrityTests.sourceTexts(in: ["Sources"]) where name != "HandOverHold.swift" {
            let code = SyncContractFenceTests.stripped(text)
            if Self.ownHolds(in: code) > 0 { own.append(name) }
            if code.contains("HandOverHold<") { taking.append(name) }
        }
        #expect(own.isEmpty, "a log keeps its own held hand-over again: \(own)")
        #expect(Set(taking).isSuperset(of: ["PodcastListenLog.swift", "PlaybackNotices.swift", "ListenHistory.swift"]),
                "a log that follows the account does not take the one hold: \(taking.sorted())")
        let caught = Self.ownHolds(in: """
            private var held: (scope: String, previous: String?)?
            private var pendingOwner: (scope: String, previous: String?)
            """)
        let passed = Self.ownHolds(in: """
            func follow(owner scope: String, previous: String? = nil) -> Bool {
            mutating func hold(scope: String, previous: String?) {
            """)
        #expect(caught == 2, "the fence misses the form under another name: \(caught)")
        #expect(passed == 0, "the fence counts a parameter list: \(passed)")
    }
}
#endif
