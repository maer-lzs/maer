import Foundation

/// Persistiert nicht gesendete Fortschritts-Updates auf der Festplatte, damit
/// sie einen App-Kill während einer Offline-Phase überleben. Ohne das wäre
/// ein Fortschritts-Update verloren, wenn die App offline geschlossen wird,
/// bevor der nächste automatische Sync-Versuch (alle 30s) drankommt.
///
/// Es wird bewusst nur der JEWEILS LETZTE Stand pro Buch gespeichert (ein
/// Dictionary, kein Verlauf) — nur der neueste Fortschritt ist relevant,
/// ältere Zwischenstände wären ohnehin überholt.
@MainActor
final class SyncQueue {
    static let shared = SyncQueue()

    private struct PendingUpdate: Codable {
        let currentTime: Double
        let duration: Double
        let isFinished: Bool
    }

    private let fileURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("pending_sync.json")

    private init() {}

    func enqueue(itemId: String, currentTime: Double, duration: Double, isFinished: Bool) {
        var pending = loadAll()
        pending[itemId] = PendingUpdate(currentTime: currentTime, duration: duration, isFinished: isFinished)
        save(pending)
    }

    func remove(itemId: String) {
        var pending = loadAll()
        guard pending[itemId] != nil else { return }
        pending.removeValue(forKey: itemId)
        save(pending)
    }

    /// True, wenn mindestens ein Update auf seinen Versand wartet — z. B. um
    /// dem Nutzer einen dezenten Hinweis zu zeigen.
    var hasPendingUpdates: Bool {
        !loadAll().isEmpty
    }

    /// Versucht, alle wartenden Updates an den Server zu schicken. Wird beim
    /// App-Start und bei Wiederverbindung aufgerufen (siehe LibraryView).
    /// Updates, die weiterhin fehlschlagen (z. B. immer noch offline),
    /// bleiben in der Queue und werden beim nächsten Aufruf erneut versucht.
    func flush(apiClient: APIClient) async {
        let pending = loadAll()
        guard !pending.isEmpty else { return }
        for (itemId, update) in pending {
            do {
                try await apiClient.updateProgress(
                    itemId: itemId,
                    currentTime: update.currentTime,
                    duration: update.duration,
                    isFinished: update.isFinished
                )
                remove(itemId: itemId)
            } catch {
                // Immer noch offline oder anderer Fehler — in der Queue
                // belassen, nächster Versuch kommt automatisch.
            }
        }
    }

    private func loadAll() -> [String: PendingUpdate] {
        guard let data = try? Data(contentsOf: fileURL),
              let dict = try? JSONDecoder().decode([String: PendingUpdate].self, from: data) else {
            return [:]
        }
        return dict
    }

    private func save(_ pending: [String: PendingUpdate]) {
        guard let data = try? JSONEncoder().encode(pending) else { return }
        try? data.write(to: fileURL)
    }
}
