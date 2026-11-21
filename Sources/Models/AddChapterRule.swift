// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation

/// "Add Chapter": each tap puts ONE chapter of a book at the end of Up
/// Next, so chapters take turns with the rest. The first tap the chapter of
/// the stand, each further one the chapter after the last one added. The
/// menu names the chapter as the book does, with its place in front only
/// when the name carries no count ("9. Er tat es").
nonisolated enum AddChapterRule {
    /// What is left of a chapter below this counts as heard.
    static let heardBelow: Double = 30

    static func ordered(_ chapters: [ABSChapter]) -> [ABSChapter] {
        chapters.sorted { $0.start < $1.start }
    }

    /// The chapter the next tap adds, nil when there is none to offer:
    /// fewer than two chapters (one is the book), the whole book or a chain
    /// of it waiting, the last chapter added, or the stand at the end. A
    /// chapter taken out again leaves the offer after the last one still
    /// waiting.
    static func next(bookId: String, chapters: [ABSChapter], position: Double, queue: [String]) -> ABSChapter? {
        let list = ordered(chapters)
        guard list.count >= 2, !queue.contains(bookId) else { return nil }
        let entries = queue.compactMap(ItemNamespace.chapterEntry).filter { $0.bookId == bookId }
        guard !entries.contains(where: \.continues) else { return nil }
        if let last = entries.map(\.startMs).max() {
            return list.first { ChapterEntryRules.ms($0.start) > last }
        }
        if let here = list.first(where: { $0.start <= position && position < $0.end }) {
            return here.end - position >= heardBelow ? here : list.first { $0.start > here.start }
        }
        return list.first { $0.start > position }
    }

    /// The name the menu and Up Next show: the book's own when it already
    /// counts, else its place in front (a preface takes a place too); a
    /// chapter without a name is its place.
    static func shown(_ chapter: ABSChapter, in chapters: [ABSChapter]) -> String {
        let place = (ordered(chapters).firstIndex { $0.start == chapter.start } ?? 0) + 1
        let name = chapter.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty { return String(localized: "Chapter \(place)") }
        return ChapterCounting.counts(name) ? name : "\(place). \(name)"
    }

    /// Whether a single chapter waiting in Up Next is heard by now: the
    /// book stands within `heardBelow` of its end or past it. It then falls
    /// out of Up Next. A chain entry follows the stand by itself and never is.
    static func heard(entryId: String, chapters: [ABSChapter], bookPosition: Double) -> Bool {
        guard let entry = ItemNamespace.chapterEntry(entryId), !entry.continues,
              let chapter = ChapterEntryRules.chapter(startMs: entry.startMs, in: chapters) else { return false }
        return bookPosition >= chapter.end - heardBelow
    }
}
