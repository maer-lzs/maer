import Foundation
import Combine
import SwiftUI   // Array.move(fromOffsets:toOffset:) for the reorder API
import WidgetKit

/// Nutzer-verwaltete „Als Nächstes"-Warteschlange für Podcast-Folgen
/// (quellenübergreifend, IDs `rss:`/`abspod:`). Persistiert lokal. Die aktuell
/// laufende Folge steht NICHT in der Queue — sie wird beim Abspielen entfernt;
/// „Als Nächstes" ist also das, was NACH der laufenden kommt (wie in gängigen
/// Podcast-Apps).
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

    /// Ganz nach vorne (als Nächstes spielen).
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

    /// Queue-Vorschau (Titel + Show der ersten Einträge) für das „Als Nächstes"-
    /// Widget in den App-Group-Container schreiben und das Widget aktualisieren.
    private func writeWidgetSnapshot() {
        let items = ids.prefix(6).compactMap { id -> PodcastQueueSnapshot.Item? in
            guard let item = AppSession.shared.libraryItem(forId: id) else { return nil }
            return PodcastQueueSnapshot.Item(title: item.title, show: item.media?.metadata?.authorName)
        }
        PodcastQueueSnapshot(items: items).save()
        WidgetCenter.shared.reloadTimelines(ofKind: "PodcastUpNext")
    }
}
