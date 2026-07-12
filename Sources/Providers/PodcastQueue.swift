import Foundation
import Combine
import SwiftUI   // Array.move(fromOffsets:toOffset:) for the reorder API
import WidgetKit

/// User-managed "Up Next" queue for podcast episodes (cross-source, ids
/// `rss:`/`abspod:`). Persisted locally. The currently playing episode is NOT
/// in the queue — it is removed on play; "Up Next" is therefore what comes
/// AFTER the current one (like common podcast apps).
@MainActor
final class PodcastQueue: ObservableObject {
    static let shared = PodcastQueue()

    @Published private(set) var ids: [String] = []

    private let fileURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("podcast_queue.json")

    private init() {
        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode([String].self, from: data) {
            ids = decoded
        }
    }

    var first: String? { ids.first }
    var isEmpty: Bool { ids.isEmpty }
    func contains(_ id: String) -> Bool { ids.contains(id) }

    /// To the very front (play next).
    func playNext(_ id: String) {
        ids.removeAll { $0 == id }
        ids.insert(id, at: 0)
        save()
    }

    /// Ans Ende der Warteschlange.
    func playLast(_ id: String) {
        guard !ids.contains(id) else { return }
        ids.append(id)
        save()
    }

    func remove(_ id: String) {
        guard ids.contains(id) else { return }
        ids.removeAll { $0 == id }
        save()
    }

    func move(from source: IndexSet, to destination: Int) {
        ids.move(fromOffsets: source, toOffset: destination)
        save()
    }

    func clear() {
        guard !ids.isEmpty else { return }
        ids = []
        save()
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(ids) else { return }
        try? data.write(to: fileURL, options: .atomic)
        writeWidgetSnapshot()
    }

    /// Write a queue preview (title + show of the first entries) for the "Up
    /// Next" widget into the App Group container and refresh the widget.
    private func writeWidgetSnapshot() {
        let items = ids.prefix(6).compactMap { id -> PodcastQueueSnapshot.Item? in
            guard let item = AppSession.shared.libraryItem(forId: id) else { return nil }
            return PodcastQueueSnapshot.Item(title: item.title, show: item.media?.metadata?.authorName)
        }
        PodcastQueueSnapshot(items: items).save()
        WidgetCenter.shared.reloadTimelines(ofKind: "PodcastUpNext")
    }
}
