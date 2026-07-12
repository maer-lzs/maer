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
        var addedLocally = 0        // vom Server neu abonniert
        var pushedToServer = 0      // lokale Abos zum Server geschoben
        var historyPulled = 0       // Episoden-Positionen vom Server übernommen
        var historyPushed = 0       // Episoden-Positionen zum Server geschoben
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
            let hist = try await syncEpisodeActions(client)
            report.historyPulled = hist.pulled
            report.historyPushed = hist.pushed
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

    // MARK: - History-Sync (Episoden-Aktionen ↔ localPosition)

    /// Server-Play-Aktionen in `localPosition` übernehmen (jüngerer Zeitstempel
    /// gewinnt) und umgekehrt seit dem letzten Push geänderte Positionen als
    /// Play-Aktionen hochladen. Match läuft über die (normalisierte) Enclosure-URL.
    private func syncEpisodeActions(_ client: GPodderClient) async throws -> (pulled: Int, pushed: Int) {
        let defaults = UserDefaults.standard
        let subs = PodcastSubscriptions.shared

        // Enclosure-URL → (rss-ID, Feed-URL, Dauer) über alle abonnierten Folgen.
        var byEnclosure: [String: (id: String, feed: String, duration: Double)] = [:]
        for (show, ep) in subs.allEpisodes() {
            byEnclosure[PodcastSubscriptions.normalizeEnclosure(ep.audioURL)] =
                (ep.guid, show.feedURL, ep.duration)
        }

        // --- Pull: Server → lokal ---
        let since = defaults.integer(forKey: AppStorageKeys.gpodderEpisodeSince)
        let (actions, newSince) = try await client.episodeActions(since: since)
        var pulled = 0
        for a in actions where (a.action?.lowercased() == "play") {
            guard let enc = a.episode, let pos = a.position,
                  let match = byEnclosure[PodcastSubscriptions.normalizeEnclosure(enc)] else { continue }
            let tsMs = Self.parseTimestamp(a.timestamp)
            let localArr = defaults.array(forKey: AppStorageKeys.localPosition(match.id)) as? [Double]
            let localTs = (localArr?.count == 2) ? localArr![1] : -1
            if tsMs > localTs {
                defaults.set([Double(pos), tsMs], forKey: AppStorageKeys.localPosition(match.id))
                pulled += 1
            }
        }
        defaults.set(newSince, forKey: AppStorageKeys.gpodderEpisodeSince)
        if pulled > 0 {
            PodcastProgressStore.shared.reload()   // UI + iCloud-Reconcile anstoßen
            PodcastCloudSync.shared.reconcile()
        }

        // --- Push: lokal → Server (nur seit dem letzten Push geändert) ---
        let lastPush = defaults.double(forKey: AppStorageKeys.gpodderLastEpisodePush)
        var out: [[String: Any]] = []
        for (show, ep) in subs.allEpisodes() {
            guard let arr = defaults.array(forKey: AppStorageKeys.localPosition(ep.guid)) as? [Double],
                  arr.count == 2 else { continue }
            let pos = arr[0], tsMs = arr[1]
            guard tsMs / 1000 > lastPush else { continue }
            out.append([
                "podcast": show.feedURL,
                "episode": ep.audioURL,
                "device": config?.deviceId ?? "",
                "action": "play",
                "timestamp": Self.isoTimestamp(tsMs),
                "started": 0,
                "position": Int(pos),
                "total": Int(ep.duration)
            ])
        }
        if !out.isEmpty {
            _ = try await client.uploadEpisodeActions(out)
            defaults.set(Date().timeIntervalSince1970, forKey: AppStorageKeys.gpodderLastEpisodePush)
        }
        return (pulled, out.count)
    }

    // MARK: - Zeitstempel (gpodder nutzt ISO 8601 ohne Zeitzone, UTC)

    private static let iso: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        return f
    }()

    /// „2009-12-12T09:00:00" → ms seit 1970 (UTC). Fallback: jetzt.
    private static func parseTimestamp(_ s: String?) -> Double {
        guard let s, !s.isEmpty else { return Date().timeIntervalSince1970 * 1000 }
        let clean = s.hasSuffix("Z") ? String(s.dropLast()) : s
        if let d = iso.date(from: clean) { return d.timeIntervalSince1970 * 1000 }
        return Date().timeIntervalSince1970 * 1000
    }

    private static func isoTimestamp(_ ms: Double) -> String {
        iso.string(from: Date(timeIntervalSince1970: ms / 1000))
    }
}
