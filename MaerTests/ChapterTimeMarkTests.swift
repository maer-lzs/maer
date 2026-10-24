// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// A jump mark names its start ("from 15:00"); the chapter row says the time
/// once, not twice.
struct ChapterTimeMarkTests {
    @Test("a jump mark of a partly chaptered file names its start")
    func jumpMarksNameTheirStart() {
        let real = ABSChapter(id: 0, start: 0, end: 600, title: "Prolog")
        let resolved = ChapterModel.withTimeMarks([real], duration: 3600)
        #expect(resolved.count > 1)
        #expect(!ChapterModel.namesItsStart(resolved[0]))
        for mark in resolved.dropFirst() {
            #expect(ChapterModel.namesItsStart(mark), "\(mark.title)")
        }
    }

    @Test("a real chapter called like a time keeps its time line unless it is its own start")
    func onlyTheOwnStartCounts() {
        let other = ABSChapter(id: 1, start: 900, end: 1800, title: ChapterModel.markTitle(600))
        #expect(!ChapterModel.namesItsStart(other))
    }

    @Test("the chapter row asks the rule and has no second time format", .needsTheSources)
    func theRowAsksTheRule() throws {
        let page = SyncContractFenceTests.stripped(
            try String(contentsOf: SourceTree.root.appendingPathComponent("Sources/Views/BookDetailScreen.swift"), encoding: .utf8))
        #expect(page.contains("if !ChapterModel.namesItsStart(chapter) {"))
        #expect(!page.contains("private func formatted(_ seconds: Double)"))
    }
}
#endif
