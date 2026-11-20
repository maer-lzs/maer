// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import SwiftUI

/// The one entry of a menu that puts an audiobook into Up Next chapter by
/// chapter, for the book's card and the catalog's menus alike; it shows only
/// where `ChapterEntryRules.offersChain` says so.
struct ChapterChainButton: View {
    let itemId: String
    let title: String
    var finished = false
    /// The stand the surface holds, for a card outside the loaded lists.
    var known: Double?
    let playerCoordinator: PlayerCoordinator

    var body: some View {
        if ChapterEntryRules.offersChain(itemId: itemId, finished: finished,
                                         markedForm: ListeningStore.startedForm(itemId)) {
            Button {
                Task { await playerCoordinator.enqueueChain(bookId: itemId, title: title, known: known) }
            } label: {
                Label("Chapter by Chapter in Up Next", systemImage: "list.bullet.indent")
            }
        }
    }
}
