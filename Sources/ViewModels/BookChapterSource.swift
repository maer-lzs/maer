// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation
import OSLog

/// The chapters of a book that its chapter entries ask: the row, the advance
/// and the start read the same list (`ChapterEntryRules.knownChapters`). A
/// server's library list carries no chapters, so a book none of the sources
/// knows yet has its detail fetched once, and every surface hears the change.
@MainActor
final class BookChapterSource {
    /// The book the player holds now, with its chapters and its position.
    private let playing: () -> (bookId: String, chapters: [ABSChapter], position: Double)?
    /// The book's item from the loaded library list, and its last known stand.
    private let listed: (String) -> LibraryItem?
    private let listedPosition: (String) -> Double?
    /// The stand this device keeps for a title outside the library (a
    /// catalog reading).
    private let storedPosition: (String) -> Double?
    /// The book's detail from its source.
    private let fetch: (String) async throws -> LibraryItemDetail
    /// Called after a fetch taught new chapters, so the rows read again.
    private let changed: () -> Void

    private var learned: [String: [ABSChapter]] = [:]
    /// Books whose detail was asked in this run: a book without chapters is
    /// not asked again at every render.
    private var asked: Set<String> = []
    private var learning: [String: Task<Void, Never>] = [:]

    init(playing: @escaping () -> (bookId: String, chapters: [ABSChapter], position: Double)?,
         listed: @escaping (String) -> LibraryItem?,
         listedPosition: @escaping (String) -> Double?,
         storedPosition: @escaping (String) -> Double? = { _ in nil },
         fetch: @escaping (String) async throws -> LibraryItemDetail,
         changed: @escaping () -> Void) {
        self.playing = playing
        self.listed = listed
        self.listedPosition = listedPosition
        self.storedPosition = storedPosition
        self.fetch = fetch
        self.changed = changed
    }

    /// The detail a book's chapters are read from, the way the open reads
    /// it: a downloaded book's saved detail first, else its source, and the
    /// saved one again when the source does not answer.
    static func detail(isDownloaded: Bool, cached: () -> LibraryItemDetail?,
                       fetch: () async throws -> LibraryItemDetail) async throws -> LibraryItemDetail {
        if isDownloaded, let saved = cached() { return saved }
        do {
            return try await fetch()
        } catch {
            guard let saved = cached() else { throw error }
            return saved
        }
    }

    /// The chapters known for a book now, nil when no source knows them.
    func chapters(of bookId: String) -> [ABSChapter]? {
        let held = playing().flatMap { $0.bookId == bookId ? $0.chapters : nil }
        return ChapterEntryRules.knownChapters(playing: held, learned: learned[bookId],
                                               listed: listed(bookId)?.media?.chapters)
    }

    /// Where the book stands now: the player's position while it holds the
    /// book, else the last stand the library knows, else its start.
    func position(of bookId: String) -> Double {
        if let held = playing(), held.bookId == bookId { return held.position }
        return listedPosition(bookId) ?? 0
    }

    /// Chapters read from the book's detail elsewhere (the chain asks it).
    func note(_ chapters: [ABSChapter], of bookId: String) {
        guard !chapters.isEmpty else { return }
        learned[bookId] = chapters
    }

    /// The row of a chapter entry; a book whose chapters are unknown has its
    /// detail asked once in the background.
    func entryItem(_ entryId: String) -> LibraryItem? {
        guard let entry = ItemNamespace.chapterEntry(entryId), let book = listed(entry.bookId) else { return nil }
        let known = chapters(of: entry.bookId)
        if known == nil { Task { await learn(entry.bookId) } }
        return ChapterEntryRules.carrier(entryId: entryId, book: book, chapters: known ?? [],
                                         bookPosition: position(of: entry.bookId))
    }

    /// Fetches the book's detail once in this run and keeps the chapters the
    /// player would show for it. A second ask while the first is on its way
    /// waits for it.
    func learn(_ bookId: String) async {
        guard chapters(of: bookId) == nil else { return }
        if let running = learning[bookId] { return await running.value }
        guard asked.insert(bookId).inserted else { return }
        let task = Task { await fetchChapters(bookId) }
        learning[bookId] = task
        await task.value
        learning[bookId] = nil
    }

    private func fetchChapters(_ bookId: String) async {
        do {
            let detail = try await fetch(bookId)
            let found = ChapterModel.resolved(detail: detail).chapters
            guard !found.isEmpty else { return }
            learned[bookId] = found
            changed()
        } catch {
            // A failed fetch may be asked again at the next render; it does
            // not render again by itself.
            asked.remove(bookId)
            Logger.player.notice("CHAPTER source: the book's detail failed: \(FailureReason.of(error), privacy: .public)")
        }
    }
}
