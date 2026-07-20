// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI
import Combine

/// Reorderable global "Up Next" page across ALL media types: reorder
/// (`.onMove`/EditButton), swipe to remove, tap a row to play it (and remove it
/// from the queue). Rows render uniformly via `PlayQueueRow`.
struct PlayQueueView: View {
    @ObservedObject var playerCoordinator: PlayerCoordinator
    @ObservedObject private var queue = PlayQueue.shared

    var body: some View {
        List {
            ForEach(queue.ids, id: \.self) { id in
                if let item = AppSession.shared.libraryItem(forId: id) {
                    PlayQueueRow(item: item, playerCoordinator: playerCoordinator)
                        .listRowInsets(EdgeInsets(top: 4, leading: 12, bottom: 4, trailing: 12))
                }
            }
            .onMove { queue.move(from: $0, to: $1) }
            .onDelete { offsets in
                offsets.map { queue.ids[$0] }.forEach { queue.remove($0) }
            }
        }
        .listStyle(.plain)
        .bottomBarClearance()
        .reportsBottomBarScroll()
        .navigationTitle("Up Next")
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
