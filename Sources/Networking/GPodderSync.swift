import Foundation

/// Gleicht Podcast-Abos (und später die Hör-History) mit einem gpodder-kompatiblen
/// Server (oPodSync, Nextcloud GPodder, gpodder.net) ab — gleichwertig neben
/// iCloud und ABS. Feeds/Wiedergabe/Downloads laufen unverändert über den
/// `RSSProvider`; dieser Dienst synchronisiert nur die Abo-Liste + `localPosition`.
@MainActor
final class GPodderSync {
    static let shared = GPodderSync()
    private init() {}

    struct Report: Equatable {
        var addedLocally = 0      // vom Server neu abonniert
        var pushedToServer = 0    // lokale Abos zum Server geschoben
        var error: String?
    }

    private var isRunning = false
    private static var didAutoReconcile = false

    /// Config aus den gespeicherten Zugangsdaten bauen (nil, wenn unvollständig).
    private var config: GPodderConfig? {
        guard AppStorageKeys.gpodderConfigured,
              let url = URL(string: AppStorageKeys.gpodderServerURLValue.trimmingCharacters(in: .whitespaces)),
              url.scheme != nil else { return nil }
        return GPodderConfig(
            baseURL: url,
            username: AppStorageKeys.gpodderUsernameValue,
            password: AppStorageKeys.gpodderPasswordValue,
            deviceId: AppStorageKeys.gpodderDeviceIdValue
        )
    }

    /// Nur Zugangsdaten prüfen (Login). Gibt `nil` bei Erfolg, sonst Fehlertext.
    func testConnection() async -> String? {
        guard let config else { return String(localized: "Please fill in server, username and password.") }
        do { try await GPodderClient(config: config).login(); return nil }
        catch { return (error as? LocalizedError)?.errorDescription ?? error.localizedDescription }
    }

    /// Abos (und History – Teil 2) abgleichen. Idempotent, nie zwei gleichzeitig.
    @discardableResult
    func reconcile() async -> Report {
        var report = Report()
        guard !isRunning else { return report }
        guard AppStorageKeys.gpodderEnabledValue, let config else { return report }
        isRunning = true
        defer { isRunning = false }

        let client = GPodderClient(config: config)
        do {
            try await client.login()
            report = try await syncSubscriptions(client)
        } catch {
            report.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
        return report
    }

    /// Einmal pro App-Session automatisch, wenn aktiviert & konfiguriert.
    func autoReconcileIfNeeded() async {
        guard !Self.didAutoReconcile, AppStorageKeys.gpodderEnabledValue, config != nil else { return }
        Self.didAutoReconcile = true
        await reconcile()
    }

    // MARK: - Abo-Sync (Union-Merge, nicht-destruktiv)

    /// Server- und lokale Abo-Liste vereinen: fehlende Feeds beidseitig ergänzen.
    /// Entfernungen werden in v1 bewusst NICHT propagiert (destruktiv) — das kommt
    /// mit sauberem Delta-Tracking später.
    private func syncSubscriptions(_ client: GPodderClient) async throws -> Report {
        var report = Report()
        let subs = PodcastSubscriptions.shared

        let serverURLs = try await client.subscriptions()
        let serverByNorm = Dictionary(serverURLs.map { (PodcastSubscriptions.normalizeFeedURL($0), $0) },
                                      uniquingKeysWith: { a, _ in a })
        let localByNorm = Dictionary(subs.shows.map { (PodcastSubscriptions.normalizeFeedURL($0.feedURL), $0.feedURL) },
                                     uniquingKeysWith: { a, _ in a })

        // Server → lokal: neue Feeds hier abonnieren (parst den Feed).
        for (norm, rawURL) in serverByNorm where localByNorm[norm] == nil {
            if await subs.subscribe(urlString: rawURL) { report.addedLocally += 1 }
        }

        // Lokal → Server: lokale, dem Server unbekannte Feeds hochladen.
        let toPush = localByNorm.filter { serverByNorm[$0.key] == nil }.map { $0.value }
        if !toPush.isEmpty {
            try await client.uploadSubscriptions(add: toPush, remove: [])
            report.pushedToServer = toPush.count
        }
        return report
    }
}
