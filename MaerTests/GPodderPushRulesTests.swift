// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// The first witnesses gpodder has for POSITIONS (every older one is about
/// subscriptions or payload decoding): the real-time throttle that a failed
/// push must not eat, and the batch cursor that must not skip a position
/// written while the batch was on its way.
struct GPodderPushRulesTests {
    @Test("ein gescheiterter Push verbraucht das Fenster nicht: der naechste innerhalb 8 s geht durch")
    func aFailedPushDoesNotEatTheWindow() {
        var throttle = GPodderPushRules.Throttle()
        #expect(throttle.shouldPush("rss:a", position: 100, nowMs: 10_000))
        throttle.noteAttempt("rss:a", position: 100, nowMs: 10_000)
        // While the attempt stands, a near tick within the window waits.
        #expect(!throttle.shouldPush("rss:a", position: 101, nowMs: 13_000), "coalesced, as before")
        // The attempt failed: the window is free again.
        throttle.noteFailure("rss:a", position: 100, nowMs: 10_000)
        #expect(throttle.shouldPush("rss:a", position: 101, nowMs: 13_000), "the next one within 8 s goes out")
    }

    @Test("ein gelungener Push haelt das Fenster, ein grosser Sprung oeffnet es")
    func aSuccessfulPushKeepsTheWindow() {
        var throttle = GPodderPushRules.Throttle()
        throttle.noteAttempt("rss:a", position: 100, nowMs: 10_000)
        #expect(!throttle.shouldPush("rss:a", position: 102, nowMs: 14_000))
        #expect(throttle.shouldPush("rss:a", position: 140, nowMs: 14_000), "a seek is not a tick")
        #expect(throttle.shouldPush("rss:a", position: 102, nowMs: 18_000), "the window passed")
        #expect(throttle.shouldPush("rss:b", position: 100, nowMs: 10_000), "another episode has its own window")
    }

    @Test("die Ruecknahme trifft nur den eigenen Versuch, nicht einen neueren")
    func takingBackOnlyRemovesTheOwnMark() {
        var throttle = GPodderPushRules.Throttle()
        throttle.noteAttempt("rss:a", position: 100, nowMs: 10_000)
        throttle.noteAttempt("rss:a", position: 150, nowMs: 11_000)
        // The first attempt fails late: the second one's mark stays.
        throttle.noteFailure("rss:a", position: 100, nowMs: 10_000)
        #expect(!throttle.shouldPush("rss:a", position: 151, nowMs: 12_000))
    }

    @Test("der Zeiger rueckt auf die Sammelzeit: ein Stand, der waehrend des Stapels entstand, geht im naechsten")
    func theCursorMovesToTheGatheringMoment() {
        let gatheredAt = 1_000.0                      // seconds: the batch is gathered
        let writtenDuringTheBatchMs = 1_001.0 * 1000  // a position lands while it is on its way
        let cursorWrittenAt = 1_002.0                 // the old cursor: the moment of writing it
        // The old rule: cursor = now, and the entry is never after it.
        #expect(!GPodderPushRules.isAfterCursor(entryMs: writtenDuringTheBatchMs, cursorSeconds: cursorWrittenAt),
                "this is the skip window the answer named")
        // The rule now: cursor = gathering moment, and the entry goes next time.
        let cursor = GPodderPushRules.cursorAfterPush(gatheredAtSeconds: gatheredAt)
        #expect(GPodderPushRules.isAfterCursor(entryMs: writtenDuringTheBatchMs, cursorSeconds: cursor))
        // And what was gathered is not gathered twice by that: an entry from
        // BEFORE the gathering stays behind the cursor.
        #expect(!GPodderPushRules.isAfterCursor(entryMs: 999.0 * 1000, cursorSeconds: cursor))
    }

    /// A source fence beside the rule: the runner uses the rule, and the
    /// bare `try?` around the real-time upload is gone.
    @Test("der Laeufer nutzt die Regel, und der Echtzeit-Push verwirft keinen Fehler mehr stumm", .needsTheSources)
    func theRunnerUsesTheRule() throws {
        let file = try #require(ProjectFileIntegrityTests.sourceFiles()
            .first { $0.lastPathComponent == "GPodderSync.swift" })
        let text = SyncContractFenceTests.stripped(try String(contentsOf: file, encoding: .utf8))
        #expect(text.contains("GPodderPushRules.Throttle"), "the throttle is the rule's")
        #expect(text.contains("cursorAfterPush(gatheredAtSeconds:"), "the cursor is the rule's")
        #expect(!text.contains("try? await GPodderClient(config: config).uploadEpisodeActions"),
                "the real-time push swallows its failure without a line")
        #expect(text.contains("noteFailure("), "a failed push takes its mark back")
    }
}
#endif
