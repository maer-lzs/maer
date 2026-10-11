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
    /// The sentence of a row that could not open; the alert says it.
    @State private var openFailure: String?

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
        .alert(Text(openFailure ?? ""), isPresented: Binding(
            get: { openFailure != nil },
            set: { if !$0 { openFailure = nil } }
        )) {
            Button("OK", role: .cancel) { openFailure = nil }
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

    private func open(_ entry: ListenHistory.Entry) async {
        switch await ListenHistoryOpen.open(entry) {
        case .opened, .cancelled: openFailure = nil
        case .unavailable(let reason): openFailure = MaerPlaylistPage.reasonText(reason)
        case .failed(let sentence): openFailure = sentence
        }
    }
}
