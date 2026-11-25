// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import SwiftUI

/// The listening history of one family (books in the books tab, songs in
/// the music tab), newest first, in the row of the episode history. One
/// continuous list, no limit, no button, no loading steps: the page sorts
/// off the main thread and reads there when nothing read the rows before
/// (`ListenHistory.historyOffMain`, which names where that is not so), and
/// the list draws only the rows on screen.
struct ListenHistoryScreen: View {
    let family: ListenHistory.Family
    @State private var entries: [ListenHistory.Entry] = []
    @State private var loaded = false
    /// The rows could not be read: said, not shown as empty.
    @State private var unread = false
    /// Every listening event reads the page again.
    @ObservedObject private var revision = ListeningRevision.shared
    /// The sentence of a row that could not open; the alert says it.
    @State private var openFailure: String?

    var body: some View {
        Group {
            if unread {
                EmptyStateView("Listening History", systemImage: "exclamationmark.triangle",
                               description: Text("Your listening history cannot be read on this device right now."))
            } else if loaded, entries.isEmpty {
                EmptyStateView("No listening history yet", systemImage: "checkmark.circle",
                               description: family == .book
                                   ? Text("Books you finish appear here.")
                                   : Text("Songs you listen to appear here."))
            } else {
                // Every row opens its target: the book, or the song's album
                // (`ListenHistoryOpen`); one that cannot says why.
                List(entries, id: \.id) { entry in
                    Button {
                        Task { await open(entry) }
                    } label: {
                        HistoryRow(title: entry.title, subtitle: entry.subtitle, date: ListenHistory.shownDate(entry))
                    }
                    .foregroundStyle(.primary)
                }
                .listStyle(.plain)
            }
        }
        .sentenceAlert($openFailure)
        .navigationTitle(Text("Listening History"))
        .navigationBarTitleDisplayMode(.large)
        // Read and sorted off the main thread, at the opening and at every
        // listening event.
        .task(id: revision.value) {
            let history = ListenHistory.shared
            entries = await history.historyOffMain(family)
            unread = history.rowsUnread
            loaded = true
        }
    }

    private func open(_ entry: ListenHistory.Entry) async {
        switch await ListenHistoryOpen.open(entry) {
        case .opened, .cancelled: openFailure = nil
        case .unavailable(let reason): openFailure = MaerPlaylistPage.reasonText(reason)
        case .failed(let sentence): openFailure = sentence
        }
    }
}
