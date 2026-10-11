// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import SwiftUI

/// The listening history of one family (books in the books tab, songs in
/// the music tab), newest first, in the row of the episode history. No
/// limit and no button: the rows come in steps (`ListenHistory.pageStep`),
/// the next step once the end of the list appears, with a short spinner.
struct ListenHistoryScreen: View {
    let family: ListenHistory.Family
    @State private var entries: [ListenHistory.Entry] = []
    @State private var shown = ListenHistory.pageStep
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
                List {
                    ForEach(entries.prefix(shown), id: \.id) { entry in
                        HistoryRow(title: entry.title, subtitle: entry.subtitle, date: ListenHistory.shownDate(entry))
                    }
                    if shown < entries.count {
                        ProgressView()
                            .frame(maxWidth: .infinity)
                            .onAppear { shown = ListenHistory.shownAfterEnd(shown, of: entries.count) }
                    }
                }
                .listStyle(.plain)
            }
        }
        .navigationTitle(Text("Listening History"))
        .navigationBarTitleDisplayMode(.large)
        // Read and sorted once per opening, on the main actor: the steps
        // only show more of this one sorted list, they never sort again.
        .onAppear {
            guard !loaded else { return }
            entries = ListenHistory.shared.history(family)
            loaded = true
        }
    }
}
