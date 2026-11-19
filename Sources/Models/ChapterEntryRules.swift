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
    /// no chapter begins there any more; the entry is then unknown and is
    /// never laid onto the chapter that now holds that moment.
    static func chapter(startMs: Int, in chapters: [ABSChapter]) -> ABSChapter? {
        chapters.first { ms($0.start) == startMs }
    }

    /// The milliseconds of a chapter's start, the form an entry carries.
    static func ms(_ seconds: Double) -> Int {
        guard seconds.isFinite, seconds >= 0 else { return -1 }
        return Int((seconds * 1000).rounded())
    }

    /// Where the entry starts: at the book's position when that lies inside
    /// the chapter, so a chapter heard in part does not begin again; else at
    /// the chapter's start.
    static func startPoint(of chapter: ABSChapter, bookPosition: Double) -> Double {
        chapter.start <= bookPosition && bookPosition < chapter.end ? bookPosition : chapter.start
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

    /// How far past its end a range still counts as ended rather than left:
    /// one tick of the clock and a little more.
    static let endGrace: Double = 3

    static func state(at time: Double, of chapter: ABSChapter) -> RangeState {
        if time < chapter.start - 1 || time > chapter.end + endGrace { return .left }
        return time >= chapter.end ? .ended : .running
    }

    /// Whether the next book of a series may follow what ended: never after
    /// a chapter entry, whose end finishes no book.
    static func seriesMayFollow(_ finishedId: String, enabled: Bool) -> Bool {
        enabled && ItemNamespace.chapterEntry(finishedId) == nil
    }

    /// Whether the stand written at `currentTime` tells the server the book
    /// is finished. The end of the last chapter as an entry is the book's
    /// end in time, but the person asked for one chapter, not the book.
    static func reportsFinished(currentTime: Double, duration: Double, inChapterEntry: Bool) -> Bool {
        !inChapterEntry && SyncRules.isFinished(currentTime: currentTime, duration: duration)
    }

    /// Whether a title offers its chapters for Up Next: books only, with at
    /// least two chapters (one chapter is the book). An episode with chapters
    /// does not, from any podcast source, and neither does music (its
    /// "chapters" are the tracks of an album), a station, a routine's rule or
    /// a chapter entry.
    static func offersChapters(itemId: String, chapters: [ABSChapter]) -> Bool {
        guard chapters.count >= 2 else { return false }
        return !ItemNamespace.isPodcastEpisode(itemId)
            && !MediaFamily.isMusicByForm(itemId)
            && !ItemNamespace.isRadio(itemId)
            && !ItemNamespace.isRoutineRule(itemId)
            && ItemNamespace.chapterEntry(itemId) == nil
    }

    /// Whether an id resolves to something the advance may start: a chapter
    /// entry only when its book resolves (`bookChapters` not nil) and no
    /// known chapter list says its chapter is gone. An empty list is a list
    /// item without its chapters; the open reads them from the detail and
    /// leaves the entry where it is when none begins at its start. Any other
    /// id asks no chapter.
    static func resolves(_ itemId: String, bookChapters: [ABSChapter]?) -> Bool {
        guard let entry = ItemNamespace.chapterEntry(itemId) else { return true }
        guard let bookChapters else { return false }
        return bookChapters.isEmpty || chapter(startMs: entry.startMs, in: bookChapters) != nil
    }

    /// The row of a chapter entry in Up Next: the chapter's title under the
    /// book's, both from the book's item. A chapter that no longer begins at
    /// the entry's start says it is unknown; the row never stands for the book.
    static func carrier(entryId: String, book: LibraryItem) -> LibraryItem {
        let startMs = ItemNamespace.chapterEntry(entryId)?.startMs ?? -1
        let found = chapter(startMs: startMs, in: book.media?.chapters ?? [])
        let metadata = book.media?.metadata
        let media = LibraryItemMedia(
            metadata: LibraryItemMetadata(title: found?.title ?? unknownChapterTitle, authorName: book.title,
                                          narratorName: metadata?.narratorName, seriesName: metadata?.seriesName,
                                          genres: metadata?.genres, publishedYear: metadata?.publishedYear,
                                          description: metadata?.description),
            duration: found.map { $0.end - $0.start },
            chapters: book.media?.chapters, tracks: book.media?.tracks)
        return LibraryItem(id: entryId, media: media, addedAt: book.addedAt)
    }

    /// The entries a person sees and the advance may start: the queue without
    /// the chapter entry that plays now.
    static func shown(_ ids: [String], running: String?) -> [String] {
        guard let running else { return ids }
        return ids.filter { $0 != running }
    }

    /// The chapter entry a restored book plays as: the first entry of the
    /// queue, when it is a chapter of this book whose chapter holds the
    /// restored position. Nil for anything else; the book is then a book.
    static func restoredEntry(queueIds: [String], bookId: String, position: Double,
                              chapters: [ABSChapter]) -> (entryId: String, chapter: ABSChapter)? {
        guard let head = queueIds.first, let entry = ItemNamespace.chapterEntry(head), entry.bookId == bookId,
              let found = chapter(startMs: entry.startMs, in: chapters),
              state(at: position, of: found) == .running else { return nil }
        return (head, found)
    }

    /// The entry that follows a chapter entry heard chapter by chapter at its
    /// end: the next chapter of the book in the same form. Nil after the last
    /// chapter, for a single chapter entry and for any other id.
    static func follower(of entryId: String, chapters: [ABSChapter]) -> String? {
        nil
    }

    /// The chapter a chain starts at: the one that holds the book's
    /// position, else the first that begins after it.
    static func chainStart(chapters: [ABSChapter], bookPosition: Double) -> ABSChapter? {
        nil
    }

    /// The chapter an entry plays: a single entry its own chapter; an entry
    /// heard chapter by chapter the chapter the book's position holds NOW,
    /// else the next, because the book may have been heard as a book since.
    static func playChapter(entryId: String, chapters: [ABSChapter], bookPosition: Double) -> ABSChapter? {
        guard let entry = ItemNamespace.chapterEntry(entryId) else { return nil }
        return chapter(startMs: entry.startMs, in: chapters)
    }

    /// Whether a book's card offers to put it into Up Next chapter by
    /// chapter: a book that is not heard to its end. Its chapters are read
    /// when the person asks, since the library list does not carry them.
    static func offersChain(itemId: String, finished: Bool) -> Bool {
        false
    }

    /// The row's title of an entry whose chapter is unknown.
    static var unknownChapterTitle: String { String(localized: "Unknown Chapter") }
}
