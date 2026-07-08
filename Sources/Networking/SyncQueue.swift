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

    struct PendingUpdate: Codable {
        let currentTime: Double
        let duration: Double
        let isFinished: Bool
        /// ms epoch beim Einreihen — für „zuletzt gehört" in der Bibliothek.
        /// Optional: Einträge aus älteren App-Versionen haben das Feld nicht.
        var queuedAt: Double? = nil
    }

    private let fileURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("pending_sync.json")

    /// Toleranz (Sekunden), ab der ein Serverstand als "weiter fortgeschritten"
    /// gilt — dieselbe Schwelle wie beim Geräte-Abgleich im PlayerViewModel.
    private let reconcileThreshold: Double = 5

    private init() {}

    func enqueue(itemId: String, currentTime: Double, duration: Double, isFinished: Bool) {
        var pending = loadAll()
        pending[itemId] = PendingUpdate(
            currentTime: currentTime,
            duration: duration,
            isFinished: isFinished,
            queuedAt: Date().timeIntervalSince1970 * 1000
        )
        save(pending)
    }

    /// Alle wartenden Updates — für die Bibliothek, damit sie den lokal
    /// neuesten (noch nicht gesendeten) Stand anzeigen kann.
    func allPending() -> [String: PendingUpdate] {
        loadAll()
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

    /// True, wenn für dieses Buch noch ein Update in der Queue liegt — damit der
    /// Player nach einem Flush prüfen kann, ob sein eigener Stand nachgereicht
    /// wurde.
    func hasPendingUpdate(itemId: String) -> Bool {
        loadAll()[itemId] != nil
    }

    /// Versucht, alle wartenden Updates an den Server zu schicken. Wird beim
    /// App-Start und bei Wiederverbindung aufgerufen (siehe LibraryView).
    /// Updates, die weiterhin fehlschlagen (z. B. immer noch offline),
    /// bleiben in der Queue und werden beim nächsten Aufruf erneut versucht.
    /// True, während ein Flush läuft — App-Start und Reconnect können sonst
    /// parallel flushen (doppelte/überholende Writes).
    private var flushInFlight = false

    func flush(apiClient: APIClient) async {
        guard !flushInFlight else { return }
        flushInFlight = true
        defer { flushInFlight = false }

        let pending = loadAll()
        guard !pending.isEmpty else { return }

        // Vor dem Schreiben einmal den aktuellen Serverstand aller Bücher holen,
        // um veraltete Offline-Updates zu erkennen. Schlägt dieser Abruf fehl
        // (z. B. weiterhin offline), wird NICHT blind geschrieben — die Queue
        // bleibt unangetastet und der nächste Aufruf versucht es erneut.
        let serverProgress: [String: BookProgress]
        do {
            serverProgress = try await apiClient.fetchAllProgress()
        } catch {
            return
        }

        for (itemId, update) in pending {
            // Eintrag kann inzwischen weg sein (aktiver Player hat erfolgreich
            // gesynct und entfernt) — dann NICHT mehr den älteren Stand schreiben.
            guard hasPendingUpdate(itemId: itemId) else { continue }
            // Servergewinn: Liegt dort inzwischen ein weiter fortgeschrittener
            // Stand — etwa weil ein anderes Gerät weitergehört hat, während
            // dieses offline war —, darf der veraltete Offline-Stand ihn nicht
            // überschreiben. Der wartende Eintrag wird dann verworfen. Ein
            // bewusstes "gehört"-Update (isFinished) bleibt davon ausgenommen,
            // da es eine Statusentscheidung ist, kein zurückgebliebener Stand.
            if !update.isFinished, update.duration > 0,
               let server = serverProgress[itemId] {
                let serverTime = server.fraction * update.duration
                if serverTime > update.currentTime + reconcileThreshold {
                    remove(itemId: itemId)
                    continue
                }
            }
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
        // Atomar: ein App-Kill mitten im Schreiben darf die Queue nicht
        // korrumpieren (loadAll liefert sonst still [:] → alles verloren).
        try? data.write(to: fileURL, options: .atomic)
    }
}
