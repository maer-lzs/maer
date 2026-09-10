// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import SwiftUI
import Combine

/// The queue as a modal sheet. THE player-queue entry surface (full-player
/// button + mini-player long-press share this ONE wrapper). Its own
/// NavigationStack carries the title and the Edit/Clear toolbar; presented as a
/// sheet it is reachable from every tab and above any pushed detail page.
struct PlayQueueSheet: View {
    @ObservedObject var playerCoordinator: PlayerCoordinator

    /// The queue lives INSIDE a sheet, so the root's playlist host cannot
    /// present over it. This hierarchy carries its own.
    @State private var playlistHost = UUID()

    var body: some View {
        NavigationStack {
            PlayQueueView(playerCoordinator: playerCoordinator)
        }
        .presentationDragIndicator(.visible)
        .playlistDialogs(id: playlistHost)
    }
}

/// Reorderable global "Up Next" page across ALL media types: reorder
/// (`.onMove`/EditButton), swipe to remove, tap a row to play it (and remove it
/// from the queue). Rows render uniformly via `PlayQueueRow`.
struct PlayQueueView: View {
    @Environment(\.itemRouter) private var router
    @ObservedObject var playerCoordinator: PlayerCoordinator
    @Environment(\.playlistHost) private var playlistHost
    @ObservedObject private var queue = PlayQueue.shared

    @ObservedObject private var context = PlaybackContext.shared

    var body: some View {
        List {
            ForEach(queue.ids, id: \.self) { id in
                // A cache miss must not blank the row: a catalogue id after a
                // cold start resolves on demand. The row fetches its detail
                // and fills in, everything else renders from the cache as
                // before.
                if let item = router.item(id) {
                    PlayQueueRow(item: item, playerCoordinator: playerCoordinator)
                        .listRowInsets(EdgeInsets(top: 4, leading: 12, bottom: 4, trailing: 12))
                } else if let stub = router.playable(id) {
                    PlayQueueRow(item: stub, playerCoordinator: playerCoordinator)
                        .listRowInsets(EdgeInsets(top: 4, leading: 12, bottom: 4, trailing: 12))
                        .task {
                            // Fills the provider's session cache; the store
                            // publish re-renders the row with its real title.
                            _ = try? await FreeCatalogProvider.shared.fetchItemDetail(itemId: id)
                            queue.objectWillChange.send()
                        }
                }
            }
            .onMove { queue.move(from: $0, to: $1) }
            .onDelete { offsets in
                offsets.map { queue.ids[$0] }.forEach { queue.remove($0) }
            }
            // The CONTEXT below the orders: what keeps playing after them,
            // and where it comes from. A display of the truth (the advance
            // rule reads the same lists in the same order); not orderable,
            // not part of the plan; a new start replaces it.
            if !context.ids.isEmpty {
                Section {
                    ForEach(context.ids, id: \.self) { id in
                        if let item = router.item(id)
                            ?? router.playable(id) {
                            PlayQueueRow(item: item, playerCoordinator: playerCoordinator)
                                .listRowInsets(EdgeInsets(top: 4, leading: 12, bottom: 4, trailing: 12))
                        }
                    }
                } header: {
                    if let source = context.sourceTitle {
                        Text("Continuing from \(source)")
                    } else {
                        Text("Continuing")
                    }
                }
                .accessibilityIdentifier("play-queue-context-section")
            }
        }
        .listStyle(.plain)
        // Sheet-only since the player became the queue's home: no floating
        // bottom bar inside a sheet (no clearance), and reporting scroll from
        // here would collapse the bar BEHIND the sheet (no reporting).
        // Locale-independent handle for the UI-test harness.
        .accessibilityIdentifier("play-queue-list")
        .navigationTitle("Up Next")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    // The most obvious way to build a playlist. Instead of
                    // searching every title again one by one. Runs through the
                    // ONE create dialog, so a queued ALBUM lands as its songs
                    // here too.
                    PlaylistPresenter.shared.askToCreate(place: .device,
                                                         ids: queue.ids,
                                                         host: playlistHost)
                } label: { Image(systemName: "text.badge.plus") }
                .accessibilityLabel(Text("Save as Playlist"))
                .accessibilityIdentifier("queue-save-as-playlist")
                .disabled(queue.ids.isEmpty)
            }
        }
        .toolbar {
            if !queue.isEmpty {
                ToolbarItem(placement: .topBarTrailing) { EditButton() }
                ToolbarItem(placement: .topBarLeading) {
                    Button("Clear", role: .destructive) { queue.clear() }
                }
            }
        }
        .overlay {
            if queue.isEmpty && context.isEmpty {
                ContentUnavailableView(
                    "Nothing up next",
                    systemImage: "text.line.first.and.arrowtriangle.forward",
                    description: Text("Add episodes with Play Next or Play Last.")
                )
            }
        }
    }
}
