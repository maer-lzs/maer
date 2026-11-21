// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import SwiftUI

/// The one entry of a menu that puts ONE chapter of an audiobook at the end
/// of Up Next per tap, for the book's card and the catalog's menus alike; it
/// shows only where `ChapterEntryRules.offersChain` says so. Two lines: "Add
/// Chapter" over the chapter the tap adds (`AddChapterRule`). It observes Up
/// Next, which also speaks when a book's chapters are learned, so the next
/// opening names the next chapter. Chapters no list carries yet are asked
/// when the entry shows; until then it has one line, and a tap reads them
/// first. With nothing left to add, the entry is gone.
struct ChapterChainButton: View {
    let itemId: String
    let title: String
    var finished = false
    /// The stand the surface holds, for a card outside the loaded lists.
    var known: Double?
    let playerCoordinator: PlayerCoordinator
    @ObservedObject private var queue = PlayQueue.shared

    var body: some View {
        if ChapterEntryRules.offersChain(itemId: itemId, finished: finished,
                                         markedForm: ListeningStore.startedForm(itemId)) {
            let source = AppSession.shared.bookChapters
            let chapters = source.chapters(of: itemId)
            let next = chapters.flatMap {
                AddChapterRule.next(bookId: itemId, chapters: $0,
                                    position: source.position(of: itemId, known: known), queue: queue.ids)
            }
            if chapters == nil || next != nil {
                Button {
                    Task { await playerCoordinator.addChapter(bookId: itemId, title: title, known: known) }
                } label: {
                    // The button's own label: a menu takes the first text as
                    // the title, the second as the line under it, the image
                    // as the sign. Inside a Label a menu shows the first alone.
                    Text("Add Chapter")
                    if let next, let chapters { Text(AddChapterRule.shown(next, in: chapters)) }
                    Image(systemName: "text.badge.plus")
                }
                .onAppear {
                    if chapters == nil { Task { await source.learn(itemId) } }
                }
            }
        }
    }
}
