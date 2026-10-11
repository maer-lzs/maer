// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import SwiftUI

/// The listening history of one family (books in the books tab, songs in
/// the music tab), newest first, in the row of the episode history. One
/// continuous list, no limit, no button, no loading steps: the rows are
/// read and sorted off the main thread (`ListenHistory.historyOffMain`)
/// and the list draws only the rows on screen.
struct ListenHistoryScreen: View {
    let family: ListenHistory.Family
    @State private var entries: [ListenHistory.Entry] = []
    @State private var loaded = false

    var body: some View {
        Group {
            if loaded, entries.isEmpty {
                ContentUnavailableView {
                    Label("No listening history yet", systemImage: "checkmark.circle")
                } description: {
                    switch family {
                    case .book: Text("Books you finish appear here.")
                    case .music: Text("Songs you listen to appear here.")
                    }
                }
            } else {
                List(entries, id: \.id) { entry in
                    HistoryRow(title: entry.title, subtitle: entry.subtitle, date: ListenHistory.shownDate(entry))
                }
                .listStyle(.plain)
            }
        }
        .navigationTitle(Text("Listening History"))
        .navigationBarTitleDisplayMode(.large)
        // Read and sorted once per opening, off the main thread.
        .task {
            guard !loaded else { return }
            entries = await ListenHistory.shared.historyOffMain(family)
            loaded = true
        }
    }
}
