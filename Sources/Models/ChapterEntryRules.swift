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

    /// Whether the end of an entry finishes its book: the end of the last
    /// chapter of a chain heard chapter by chapter does, as the book's own
    /// end does; a single chapter never does, not even the last.
    static func finishesBook(entryId: String, chapter: ABSChapter, chapters: [ABSChapter]) -> Bool {
        guard let entry = ItemNamespace.chapterEntry(entryId), entry.continues else { return false }
        let played = ItemNamespace.chapterEntryId(bookId: entry.bookId, startMs: ms(chapter.start), continues: true)
        return follower(of: played, chapters: chapters) == nil
    }

    /// Whether the stand of the loaded book belongs to a chapter entry, so
    /// its write tells the server nothing is finished: while the entry plays,
    /// and after the book's end as an entry as long as the position stands at
    /// that end. A finish marked by hand wins over both; a jump or playing on
    /// moves the position off the end and ends it.
    static func entryHoldsStand(playsEntry: Bool, endedAsEntry: Bool, currentTime: Double,
                                duration: Double, isFinished: Bool) -> Bool {
        !isFinished && (playsEntry || (endedAsEntry && currentTime >= duration))
    }

    /// Whether a title offers its chapters for Up Next: books only, with at
    /// least two chapters (one chapter is the book). An episode with chapters
    /// does not, from any podcast source, and neither does music (its
    /// "chapters" are the tracks of an album), a station, a routine's rule or
    /// a chapter entry.
    /// `shownAsBook`: the surface shows a book (the book's page, the player
    /// of a title that is no music), which a music server's audiobook is
    /// although its id is a music album's. Without it only an id of the book
    /// family offers chapters, never a catalogue album or music.
    static func offersChapters(itemId: String, chapters: [ABSChapter], shownAsBook: Bool = false) -> Bool {
        guard chapters.count >= 2 else { return false }
        return !ItemNamespace.isPodcastEpisode(itemId)
            && (shownAsBook || MediaFamily.of(itemId) == .book)
            && !ItemNamespace.isRadio(itemId)
            && !ItemNamespace.standsForShow(itemId)
            && ItemNamespace.chapterEntry(itemId) == nil
    }

    /// Whether an id resolves to something the advance may start: a chapter
    /// entry only when its book resolves (`bookChapters` not nil) and no
    /// known chapter list says the chapter it plays is gone (`playChapter`:
    /// a chain the chapter of the book's position). An empty list is a book
    /// whose chapters are not known yet; the open reads them from the detail
    /// and leaves the entry where it is when it plays none. Any other id asks
    /// no chapter.
    static func resolves(_ itemId: String, bookChapters: [ABSChapter]?, bookPosition: Double) -> Bool {
        guard ItemNamespace.chapterEntry(itemId) != nil else { return true }
        guard let bookChapters else { return false }
        return bookChapters.isEmpty
            || playChapter(entryId: itemId, chapters: bookChapters, bookPosition: bookPosition) != nil
    }

    /// The chapters a book's entries ask, from the first source that knows
    /// them: the player that holds the book, the chapters read from its
    /// detail, its item in the library list (a server's list carries none).
    /// Nil when none knows them.
    static func knownChapters(playing: [ABSChapter]?, learned: [ABSChapter]?,
                              listed: [ABSChapter]?) -> [ABSChapter]? {
        [playing, learned, listed].lazy.compactMap { $0 }.first { !$0.isEmpty }
    }

    /// The row of a chapter entry in Up Next: the title of the chapter it
    /// plays (`playChapter`) under the book's. A chapter it cannot name says
    /// it is unknown; the row never stands for the book.
    static func carrier(entryId: String, book: LibraryItem, chapters: [ABSChapter], bookPosition: Double) -> LibraryItem {
        let found = playChapter(entryId: entryId, chapters: chapters, bookPosition: bookPosition)
        let metadata = book.media?.metadata
        let media = LibraryItemMedia(
            metadata: LibraryItemMetadata(title: found.map { AddChapterRule.shown($0, in: chapters) } ?? unknownChapterTitle,
                                          authorName: book.title,
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
              let found = playChapter(entryId: head, chapters: chapters, bookPosition: position),
              state(at: position, of: found) == .running else { return nil }
        return (head, found)
    }

    /// The entry that follows a chapter entry heard chapter by chapter at its
    /// end: the next chapter of the book in the same form. Nil after the last
    /// chapter, for a single chapter entry and for any other id.
    static func follower(of entryId: String, chapters: [ABSChapter]) -> String? {
        guard let entry = ItemNamespace.chapterEntry(entryId), entry.continues else { return nil }
        let start = Double(entry.startMs) / 1000
        guard let next = chapters.sorted(by: { $0.start < $1.start }).first(where: { $0.start > start }) else { return nil }
        return ItemNamespace.chapterEntryId(bookId: entry.bookId, startMs: ms(next.start), continues: true)
    }

    /// The chapter a chain starts at: the one that holds the book's
    /// position, else the first that begins after it.
    static func chainStart(chapters: [ABSChapter], bookPosition: Double) -> ABSChapter? {
        let ordered = chapters.sorted { $0.start < $1.start }
        return ordered.first { $0.start <= bookPosition && bookPosition < $0.end }
            ?? ordered.first { $0.start > bookPosition }
    }

    /// The chapter an entry plays: a single entry its own chapter; an entry
    /// heard chapter by chapter the chapter the book's position holds NOW,
    /// else the next, because the book may have been heard as a book since.
    static func playChapter(entryId: String, chapters: [ABSChapter], bookPosition: Double) -> ABSChapter? {
        guard let entry = ItemNamespace.chapterEntry(entryId) else { return nil }
        if entry.continues { return chainStart(chapters: chapters, bookPosition: bookPosition) }
        return chapter(startMs: entry.startMs, in: chapters)
    }

    /// Whether a title offers to go into Up Next chapter by chapter: an
    /// audiobook that is not heard to its end, from a server, this device or
    /// a catalog (`MediaFamily.booksTabMember`: a catalog release by its
    /// started form, never a song address or a Jamendo title). Its chapters
    /// are read when the person asks, since no list carries them.
    static func offersChain(itemId: String, finished: Bool, markedForm: ProgressMark.StartedForm?) -> Bool {
        !finished && ItemNamespace.chapterEntry(itemId) == nil
            && MediaFamily.booksTabMember(itemId, markedForm: markedForm)
    }

    /// Whether this device holds a title as heard to its end: its stored
    /// mark stands at the end or says played (`ProgressMark.reachedEnd`).
    /// A title without a mark is not heard.
    static func heardToTheEnd(stored: [Double]?) -> Bool {
        stored.map { ProgressMark.reachedEnd(stored: $0, currentDuration: 0) } ?? false
    }

    /// What became of a book asked into Up Next chapter by chapter.
    enum ChainOutcome: Equatable, Sendable {
        case queued
        /// A chain of the book waits in Up Next already.
        case waitsAlready
        /// No chapter holds the book's position or begins after it.
        case noChapterLeft
        /// The book cannot go into Up Next chapter by chapter: it has fewer
        /// than two chapters, or the queue cannot hold its entries.
        case notHeld
    }

    /// The sentence a refused chain says, nil when it was queued.
    static func chainRefusal(_ outcome: ChainOutcome) -> String? {
        switch outcome {
        case .queued: return nil
        case .waitsAlready: return String(localized: "This book already waits in Up Next.")
        case .noChapterLeft: return String(localized: "No chapter follows from here.")
        case .notHeld: return String(localized: "This book cannot go into Up Next.")
        }
    }

    /// The row's title of an entry whose chapter is unknown.
    static var unknownChapterTitle: String { String(localized: "Unknown Chapter") }
}
