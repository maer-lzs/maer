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

    /// 3-Wege-Merge Server ↔ lokal ↔ zuletzt synchronisierter Stand: neue Feuds
    /// beidseitig ergänzen UND Abbestellungen propagieren. Der zuletzt
    /// synchronisierte Stand (normalisierte URLs) unterscheidet „neu abonniert"
    /// von „abbestellt". Erster Lauf (leerer Vorstand) = nicht-destruktive Union.
    private func syncSubscriptions(_ client: GPodderClient) async throws -> Report {
        var report = Report()
        let subs = PodcastSubscriptions.shared
        let defaults = UserDefaults.standard

        let serverURLs = try await client.subscriptions()
        let serverByNorm = Dictionary(serverURLs.map { (PodcastSubscriptions.normalizeFeedURL($0), $0) },
                                      uniquingKeysWith: { a, _ in a })
        let localByNorm = Dictionary(subs.shows.map { (PodcastSubscriptions.normalizeFeedURL($0.feedURL), $0.feedURL) },
                                     uniquingKeysWith: { a, _ in a })
        let prev = Set((defaults.array(forKey: AppStorageKeys.gpodderLastSyncedFeeds) as? [String]) ?? [])

        let local = Set(localByNorm.keys)
        let server = Set(serverByNorm.keys)

        // Genuine Adds (nur eine Seite, nicht im Vorstand) → auf die andere Seite.
        let addToServer = local.subtracting(server).subtracting(prev)
        let addLocally = server.subtracting(local).subtracting(prev)
        // Genuine Removes (war synchron, jetzt nur noch eine Seite) → abbestellen.
        let removeFromServer = prev.intersection(server).subtracting(local)
        let removeLocally = prev.intersection(local).subtracting(server)

        // Server-Seite: add + remove in einem Request.
        if !addToServer.isEmpty || !removeFromServer.isEmpty {
            try await client.uploadSubscriptions(
                add: addToServer.compactMap { localByNorm[$0] },
                remove: removeFromServer.compactMap { serverByNorm[$0] }
            )
            report.pushedToServer = addToServer.count
        }
        // Lokale Seite: neue Feeds abonnieren, abbestellte entfernen.
        var addedLocallyNorms = Set<String>()
        for norm in addLocally {
            if let raw = serverByNorm[norm], await subs.subscribe(urlString: raw) {
                report.addedLocally += 1
                addedLocallyNorms.insert(norm)
            }
        }
        for norm in removeLocally {
            if let show = subs.shows.first(where: { PodcastSubscriptions.normalizeFeedURL($0.feedURL) == norm }) {
                subs.unsubscribe(id: show.id)
            }
        }

        // Konvergierter Stand = in beiden vorhanden + beidseitige Neuzugänge.
        // Nur ERFOLGREICH lokal abonnierte zählen → fehlgeschlagene werden beim
        // nächsten Lauf erneut versucht (statt dauerhaft als „synchron" zu gelten).
        let converged = local.intersection(server).union(addToServer).union(addedLocallyNorms)
        defaults.set(Array(converged), forKey: AppStorageKeys.gpodderLastSyncedFeeds)
        return report
    }

    // MARK: - Echtzeit-Push (einzelne Folge beim Hören/Pausieren)

    /// Vom Player aufgerufen, sobald eine `rss:`-Folge Fortschritt schreibt
    /// (periodisch + bei Pause/Stop/Seek). Schiebt eine einzelne Play-Aktion an
    /// den Server — best effort, blockiert die Wiedergabe nicht.
    func notePlayback(rssItemId: String, position: Double, duration: Double) {
        guard AppStorageKeys.gpodderEnabledValue, config != nil,
              rssItemId.hasPrefix("rss:") else { return }
        Task { await pushSingle(rssItemId: rssItemId, position: position, duration: duration) }
    }

    private func pushSingle(rssItemId: String, position: Double, duration: Double) async {
        guard let config,
              let found = PodcastSubscriptions.shared.episode(guid: rssItemId) else { return }
        let total = duration > 0 ? duration : found.episode.duration
        let action: [String: Any] = [
            "podcast": found.show.feedURL,
            "episode": found.episode.audioURL,
            "device": config.deviceId,
            "action": "play",
            "timestamp": Self.isoTimestamp(Date().timeIntervalSince1970 * 1000),
            "started": 0,
            "position": Int(position),
            "total": Int(total)
        ]
        _ = try? await GPodderClient(config: config).uploadEpisodeActions([action])
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
