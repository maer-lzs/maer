// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Foundation
import Testing
@testable import Maer

/// Download while you listen: a book you start and the books in Continue
/// Listening download in full on Wi-Fi, within a space in GB; when it is
/// full, the automatic book heard longest ago goes; a finished one goes a
/// day later; under 2 GB free nothing downloads; books downloaded by hand
/// never count. The next book of a series downloads after one is finished
/// when its switch is on.
struct AudiobookPreloadTests {
    private static let gb: Int64 = 1_000_000_000
    private static let day: Double = 86_400_000

    @Test("the space is 2, 5 or 10 GB, 5 by default; 2 GB stay free; a finished book stays one day")
    func numbers() {
        #expect(AudiobookPreload.budgetsGB == [2, 5, 10])
        #expect(AudiobookPreload.defaultBudgetGB == 5)
        #expect(AudiobookPreload.budgetBytes(gb: 5) == 5 * Self.gb)
        #expect(AudiobookPreload.reserveBytes == 2 * Self.gb)
        #expect(AudiobookPreload.keepAfterFinishMs == Self.day)
    }

    @Test("only with the switch on and only on Wi-Fi")
    func gate() {
        #expect(AudiobookPreload.mayLoad(enabled: true, onWiFi: true))
        #expect(!AudiobookPreload.mayLoad(enabled: true, onWiFi: false))
        #expect(!AudiobookPreload.mayLoad(enabled: false, onWiFi: true))
    }

    @Test("the started book first, then Continue Listening, then the next of the series; each once")
    func candidates() {
        #expect(AudiobookPreload.candidates(started: "b", continueRow: ["a", "b", "c"], nextInSeries: "d") == ["b", "a", "c", "d"])
        #expect(AudiobookPreload.candidates(started: nil, continueRow: ["a"], nextInSeries: nil) == ["a"])
    }

    @Test("books that fit download; one already held does not again")
    func fits() {
        let wanted = [AudiobookPreload.Book(id: "a", bytes: Self.gb, lastHeardMs: 10),
                      AudiobookPreload.Book(id: "b", bytes: Self.gb, lastHeardMs: 9)]
        let plan = AudiobookPreload.plan(wanted: wanted, held: [AudiobookPreload.Book(id: "b", bytes: Self.gb, lastHeardMs: 9)],
                                         budgetBytes: 5 * Self.gb, freeBytes: 50 * Self.gb, nowMs: 100)
        #expect(plan.download == ["a"])
        #expect(plan.remove.isEmpty)
    }

    @Test("full: the automatic book heard longest ago goes for a book heard later; never one heard later than the new one")
    func full() {
        let held = [AudiobookPreload.Book(id: "old", bytes: 2 * Self.gb, lastHeardMs: 1),
                    AudiobookPreload.Book(id: "mid", bytes: 2 * Self.gb, lastHeardMs: 3)]
        let wanted = [AudiobookPreload.Book(id: "new", bytes: 2 * Self.gb, lastHeardMs: 5)]
        let plan = AudiobookPreload.plan(wanted: wanted, held: held, budgetBytes: 5 * Self.gb, freeBytes: 50 * Self.gb, nowMs: 100)
        #expect(plan.download == ["new"])
        #expect(plan.remove == ["old"])
        let older = [AudiobookPreload.Book(id: "older", bytes: 2 * Self.gb, lastHeardMs: 0)]
        let kept = AudiobookPreload.plan(wanted: older, held: held, budgetBytes: 5 * Self.gb, freeBytes: 50 * Self.gb, nowMs: 100)
        #expect(kept.download.isEmpty && kept.remove.isEmpty, "a book heard longer ago pushed out one heard later")
    }

    @Test("a book larger than the whole space never downloads")
    func tooLarge() {
        let plan = AudiobookPreload.plan(wanted: [AudiobookPreload.Book(id: "huge", bytes: 6 * Self.gb, lastHeardMs: 5)],
                                         held: [], budgetBytes: 5 * Self.gb, freeBytes: 50 * Self.gb, nowMs: 100)
        #expect(plan.download.isEmpty)
    }

    @Test("under 2 GB left on the device after the download nothing downloads")
    func reserve() {
        let book = AudiobookPreload.Book(id: "a", bytes: Self.gb + Self.gb / 2, lastHeardMs: 5)
        #expect(AudiobookPreload.plan(wanted: [book], held: [], budgetBytes: 5 * Self.gb, freeBytes: 3 * Self.gb, nowMs: 100).download.isEmpty)
        #expect(AudiobookPreload.plan(wanted: [book], held: [], budgetBytes: 5 * Self.gb, freeBytes: 4 * Self.gb, nowMs: 100).download == ["a"])
    }

    @Test("a finished automatic book goes a day after it was finished, not before")
    func finished() {
        let now = 10 * Self.day
        let held = [AudiobookPreload.Book(id: "done", bytes: Self.gb, lastHeardMs: 1, finishedAtMs: now - Self.day - 1),
                    AudiobookPreload.Book(id: "fresh", bytes: Self.gb, lastHeardMs: 2, finishedAtMs: now - 1000)]
        let plan = AudiobookPreload.plan(wanted: [], held: held, budgetBytes: 5 * Self.gb, freeBytes: 50 * Self.gb, nowMs: now)
        #expect(plan.remove == ["done"])
    }

    @Test("Fence: the settings carry the section in its words, the switch of the series starts, the runner asks the rule and records its own downloads", .needsTheSources)
    func surfaces() throws {
        func code(_ path: String) throws -> String {
            SyncContractFenceTests.stripped(try String(contentsOf: SourceTree.root.appendingPathComponent(path), encoding: .utf8))
        }
        let settings = try code("Sources/Views/SettingsView.swift")
        for words in ["\"Download Automatically\"", "\"Download While You Listen\"", "\"Space for It\"",
                      "\"Download Next Book in Series Automatically\"", "\"Start Next Book in Series Automatically\""] {
            #expect(settings.contains(words), "the settings miss \(words)")
        }
        let all = ProjectFileIntegrityTests.sourceTexts(in: ["Sources"]).map { SyncContractFenceTests.stripped($0.1) }.joined(separator: "\n")
        #expect(all.contains("AudiobookPreload.plan("), "no runner asks the rule")
        #expect(all.contains("AudiobookPreload.mayLoad("), "no runner asks the gate")
        #expect(all.contains("AppStorageKeys.audiobookAutoDownloadedIds"), "the automatic downloads are not recorded")
    }
}
#endif
