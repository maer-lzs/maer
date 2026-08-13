// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import SwiftUI
import Combine

/// The queue as a modal sheet — THE player-queue entry surface (full-player
/// button + mini-player long-press share this ONE wrapper). Its own
/// NavigationStack carries the title and the Edit/Clear toolbar; presented as a
/// sheet it is reachable from every tab and above any pushed detail page.
struct PlayQueueSheet: View {
    @ObservedObject var playerCoordinator: PlayerCoordinator

    var body: some View {
        NavigationStack {
            PlayQueueView(playerCoordinator: playerCoordinator)
        }
        .presentationDragIndicator(.visible)
    }
}

/// Reorderable global "Up Next" page across ALL media types: reorder
/// (`.onMove`/EditButton), swipe to remove, tap a row to play it (and remove it
/// from the queue). Rows render uniformly via `PlayQueueRow`.
struct PlayQueueView: View {
    @State private var showSaveSheet = false
    @State private var newListName = ""
    @ObservedObject var playerCoordinator: PlayerCoordinator
    @ObservedObject private var queue = PlayQueue.shared

    var body: some View {
        List {
            ForEach(queue.ids, id: \.self) { id in
                // A cache miss must not blank the row: a catalogue id after a
                // cold start resolves on demand — the row fetches its detail
                // and fills in, everything else renders from the cache as
                // before.
                if let item = AppSession.shared.libraryItem(forId: id) {
                    PlayQueueRow(item: item, playerCoordinator: playerCoordinator)
                        .listRowInsets(EdgeInsets(top: 4, leading: 12, bottom: 4, trailing: 12))
                } else if let stub = AppSession.shared.playableItem(forId: id) {
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
                    showSaveSheet = true
                } label: { Image(systemName: "text.badge.plus") }
                .accessibilityLabel(Text("Save as Playlist"))
                .accessibilityIdentifier("queue-save-as-playlist")
                .disabled(PlayQueue.shared.ids.isEmpty)
            }
        }
        .alert("Save as Playlist", isPresented: $showSaveSheet) {
            TextField("Name", text: $newListName)
            Button("Create") {
                // ERWEITERUNG 7baf2c2 Punkt 4: die naheliegendste Art, eine
                // Playlist anzulegen — statt jeden Titel einzeln zu suchen.
                let name = newListName.isEmpty ? String(localized: "Playlist") : newListName
                MaerPlaylists.shared.create(name: name, itemIds: PlayQueue.shared.ids)
                newListName = ""
            }
            Button("Cancel", role: .cancel) { newListName = "" }
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
            if queue.isEmpty {
                ContentUnavailableView(
                    "Nothing up next",
                    systemImage: "text.line.first.and.arrowtriangle.forward",
                    description: Text("Add episodes with Play Next or Play Last.")
                )
            }
        }
    }
}
