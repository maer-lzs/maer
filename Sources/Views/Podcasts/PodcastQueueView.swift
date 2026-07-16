import SwiftUI
import Combine

/// Reorderable "queue" page: reorder (`.onMove`/EditButton), swipe to remove,
/// tap a row to play it (and remove it from the queue).
struct PodcastQueueView: View {
    @ObservedObject var playerCoordinator: PlayerCoordinator
    @ObservedObject private var queue = PlayQueue.shared

    var body: some View {
        List {
            ForEach(queue.ids, id: \.self) { id in
                if let item = AppSession.shared.libraryItem(forId: id) {
                    PodcastEpisodeRow(item: item, playerCoordinator: playerCoordinator)
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
