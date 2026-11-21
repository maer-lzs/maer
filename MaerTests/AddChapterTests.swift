// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// "Add Chapter": one chapter per tap at the end of Up Next, named as the
/// book names it, with its place in front only when the name carries no
/// count of its own ("9. Er tat es", never "3. III Er tat es").
struct AddChapterTests {
    /// Every form a name can count in, and the traps that only look like a
    /// count. Abstract forms; the forms of real libraries were measured
    /// against the same list.
    static let counting: [(String, Bool)] = [
        ("01 - Peter Breaks Through", true), ("1. Er tat es", true), ("Chapter 3", true),
        ("Chapter III: The Storm", true), ("Kapitel IV", true), ("Kapitel vier", true),
        ("Part Two", true), ("Book the First", true), ("Erstes Kapitel", true), ("3. Kapitel", true),
        ("First Chapter", true), ("III. Er tat es", true), ("XII", true), ("IV - Der Sturm", true),
        ("One: The Beginning", true), ("Stave One", true), ("12", true), ("007", true),
        ("Part 2 of 17", true), ("Teil 3 von 12", true), ("Letter 4", true), ("Track 1", true),
        ("MCMLXXXIV", true), ("LIV", true), ("I", true), ("I.", true), ("VI - Mix", true), ("Kapitel 1984", true),
        ("Der Schimmelreiter - Teil 01", true), ("Kohlhaas Teil 01", true), ("Mowgli's Brothers (part 1)", true),
        ("Day One", true), ("Part I", true), ("CD_7", true), ("Abendrot 03", true), ("Sternenreich 01-02", true),
        ("1984", false), ("1984 Revisited", false), ("I Am Legend", false), ("I, Robot", false),
        ("Catch-22", false), ("Mix Tape", false), ("Vicky", false), ("Civil War", false),
        ("Dix Mille", false), ("Liv", false), ("Mad Max", false), ("Did It", false),
        ("Preface and Author's Note", false), ("Intro", false), ("Prolog", false), ("Credits", false),
        ("The First Snow", false), ("Zwei Freunde", false), ("One Day", false), ("Eins mit allem", false),
        ("ab 0:15:00", false), ("call_of_the_wild_1_london_64kb", false), ("Die drei ??? und", false),
        ("Chapter", false), ("Kapitel", false), ("C", false), ("Mix", false), ("Ivy", false), ("Dim Lights", false),
        ("A Day in the Life", false), ("Book of Days", false), ("Part of Me", false), ("Brief an den Vater", false),
        ("The Last Act", false), ("Book Ivy", false), ("Juli 14: Am Fluss", false), ("Prolog: 1350 Am Rhein", false),
        ("Am 3. Juli", false), ("Am 14. Juli 1789", false), ("Juli 14", false), ("", false),
    ]

    @Test("a name counts in any form; a year, a title's number, a Roman letter as a word do not")
    func countingForms() {
        for (name, counts) in Self.counting {
            #expect(ChapterCounting.counts(name) == counts, "\(name)")
        }
    }

    @Test("a file name is a name without a space, with underscores or an audio ending")
    func fileNames() {
        for name in ["call_of_the_wild_1_london_64kb", "track01.mp3", "kapitel_03", "Part1.m4b"] {
            #expect(ChapterCounting.isFileName(name), "\(name)")
        }
        for name in ["02 - The Shadow", "Er tat es", "Chapter 3", "Prolog", "CD_7 Am Rhein"] {
            #expect(!ChapterCounting.isFileName(name), "\(name)")
        }
    }

    static func chapters(_ names: [String], length: Double = 600) -> [ABSChapter] {
        names.enumerated().map { ABSChapter(id: $0.offset, start: Double($0.offset) * length,
                                            end: Double($0.offset + 1) * length, title: $0.element) }
    }

    static func entry(_ book: String, _ chapter: ABSChapter, continues: Bool = false) -> String {
        ItemNamespace.chapterEntryId(bookId: book, startMs: ChapterEntryRules.ms(chapter.start), continues: continues)
    }

    @Test("the shown name: the book's own when it counts, else its place in front; a preface takes a place; no name is its place")
    func shownName() {
        let book = Self.chapters(["Preface", "Er tat es", "Chapter 3", "III. Der Sturm", ""])
        #expect(AddChapterRule.shown(book[0], in: book) == "1. Preface")
        #expect(AddChapterRule.shown(book[1], in: book) == "2. Er tat es")
        #expect(AddChapterRule.shown(book[2], in: book) == "Chapter 3")
        #expect(AddChapterRule.shown(book[3], in: book) == "III. Der Sturm", "never 4. III. Der Sturm")
        #expect(AddChapterRule.shown(book[4], in: book) == String(localized: "Chapter \(5)"))
    }

    @Test("the next tap's chapter: the stand's chapter, its last 30 s counting as heard; then the one after the last added")
    func nextChapter() {
        let book = Self.chapters(["A", "B", "C", "D"])
        func next(_ position: Double, _ queue: [String] = []) -> String? {
            AddChapterRule.next(bookId: "b", chapters: book, position: position, queue: queue)?.title
        }
        #expect(next(0) == "A", "not begun: the first")
        #expect(next(900) == "B", "in the middle of B")
        #expect(next(1_190) == "C", "ten seconds of B left count as heard")
        #expect(next(1_170) == "B", "thirty seconds left still play")
        #expect(next(900, [Self.entry("b", book[1])]) == "C", "B waits: C")
        #expect(next(900, [Self.entry("b", book[1]), Self.entry("b", book[2])]) == "D")
        #expect(next(900, [Self.entry("b", book[2])]) == "D", "B was taken out, C waits: after the last added")
        #expect(next(900, [Self.entry("b", book[3])]) == nil, "the last waits: no entry")
        #expect(next(2_390) == nil, "the end of the book")
        #expect(next(900, ["b"]) == nil, "the whole book waits: no chapters of it")
        #expect(next(900, [Self.entry("b", book[1], continues: true)]) == nil, "a chain of the book waits: the whole book")
        #expect(next(900, [Self.entry("other", book[2])]) == "B", "another book's chapters do not count")
        #expect(AddChapterRule.next(bookId: "b", chapters: Self.chapters(["Only"]), position: 0, queue: []) == nil,
                "one chapter is the book")
        #expect(AddChapterRule.next(bookId: "b", chapters: [], position: 0, queue: []) == nil, "no chapters, no entry")
    }

    @Test("a waiting chapter is heard once the book stands within 30 s of its end; a chain entry never is")
    func heardChapters() {
        let book = Self.chapters(["A", "B", "C"])
        let b = Self.entry("b", book[1])
        #expect(!AddChapterRule.heard(entryId: b, chapters: book, bookPosition: 900))
        #expect(AddChapterRule.heard(entryId: b, chapters: book, bookPosition: 1_180))
        #expect(AddChapterRule.heard(entryId: b, chapters: book, bookPosition: 1_500))
        #expect(!AddChapterRule.heard(entryId: Self.entry("b", book[1], continues: true), chapters: book, bookPosition: 1_500))
        #expect(!AddChapterRule.heard(entryId: "b", chapters: book, bookPosition: 1_500))
    }

    @Test("chapters that follow the files keep the server's names; a file name or none reads Part N of M")
    func serverNames() {
        let tracks = (0..<3).map { ABSAudioTrack(index: $0, startOffset: Double($0) * 600, duration: 600,
                                                 contentUrl: "t\($0).mp3", metadata: nil) }
        let raw = Self.chapters(["01 - The Shadow", "call_of_the_wild_2_64kb", ""])
        let resolved = ChapterModel.resolved(chapters: raw, tracks: tracks, duration: 1_800)
        #expect(resolved.chapters.map(\.title) == ["01 - The Shadow", String(localized: "Part \(2) of \(3)"),
                                                   String(localized: "Part \(3) of \(3)")])
        #expect(resolved.chapters.map(\.start) == [0, 600, 1_200])
    }

    @Test("the menu's entry observes Up Next and the learned chapters, adds one chapter, and the rows use the shown name", .needsTheSources)
    func surfaces() throws {
        func code(_ path: String) throws -> String {
            SyncContractFenceTests.stripped(try String(contentsOf: SourceTree.root.appendingPathComponent(path), encoding: .utf8))
        }
        let button = try code("Sources/Views/ChapterChainButton.swift")
        #expect(button.contains("@ObservedObject"), "the menu does not rebuild when a chapter is added or learned")
        #expect(button.contains("AddChapterRule.next(") && button.contains("AddChapterRule.shown("))
        #expect(button.contains("addChapter("))
        #expect(!button.contains("enqueueChain("), "the chain to the book's end is gone from the menu")
        #expect(try code("Sources/Models/ChapterEntryRules.swift").contains("AddChapterRule.shown("), "Up Next shows the bare name")
        #expect(try code("Sources/ViewModels/PlayerCoordinator.swift").contains("AddChapterRule.heard("), "a heard chapter stays in Up Next")
        let catalog = try String(contentsOf: SourceTree.root.appendingPathComponent("Sources/Localizable.xcstrings"), encoding: .utf8)
        #expect(catalog.contains("\"Add Chapter\" : {") && catalog.contains("\"Kapitel hinzufügen\""))
    }
}
#endif
