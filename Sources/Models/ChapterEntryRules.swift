// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation

/// A chapter of a book in Up Next (`ItemNamespace.chapterEntryId`): which
/// chapter it names, where it starts, when its range is over, and what the
/// queue, the advance and the sync make of it. The book keeps its one
/// position; a chapter entry has none of its own.
nonisolated enum ChapterEntryRules {
    /// The chapter an entry names: the one that begins at its start. Nil when
    /// no chapter begins there any more; the entry is then unknown.
    static func chapter(startMs: Int, in chapters: [ABSChapter]) -> ABSChapter? {
        nil
    }

    /// The milliseconds of a chapter's start, the form an entry carries.
    static func ms(_ seconds: Double) -> Int { 0 }

    /// Where the entry starts: at the book's position when that lies inside
    /// the chapter, else at the chapter's start.
    static func startPoint(of chapter: ABSChapter, bookPosition: Double) -> Double {
        bookPosition
    }

    enum RangeState: Equatable, Sendable {
        /// Playing inside the chapter.
        case running
        /// The chapter's end is reached: the next entry of Up Next starts.
        case ended
        /// The person moved out of the chapter: the book plays on as a
        /// book, and the entry asks nothing more.
        case left
    }

    static func state(at time: Double, of chapter: ABSChapter) -> RangeState {
        .running
    }

    /// Whether the next book of a series may follow what ended.
    static func seriesMayFollow(_ finishedId: String, enabled: Bool) -> Bool {
        enabled
    }

    /// Whether the stand written at `currentTime` tells the server the book
    /// is finished.
    static func reportsFinished(currentTime: Double, duration: Double, inChapterEntry: Bool) -> Bool {
        SyncRules.isFinished(currentTime: currentTime, duration: duration)
    }

    /// Whether a title offers its chapters for Up Next.
    static func offersChapters(itemId: String, chapters: [ABSChapter]) -> Bool {
        true
    }

    /// Whether an id resolves to something the advance may start, given the
    /// chapters of its book when they are known.
    static func resolves(_ itemId: String, bookChapters: [ABSChapter]?) -> Bool {
        true
    }

    /// The row of a chapter entry in Up Next.
    static func carrier(entryId: String, book: LibraryItem) -> LibraryItem {
        book
    }

    /// The row's title of an entry whose chapter is unknown.
    static var unknownChapterTitle: String { "" }
}
