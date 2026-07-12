import Foundation

/// Reconciles podcast subscriptions (and later the listening history) with a
/// gpodder-compatible server (oPodSync, Nextcloud GPodder, gpodder.net) — on par
/// with iCloud and ABS. Feeds/playback/downloads still go through the
/// `RSSProvider`; this service only syncs the subscription list + `localPosition`.
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

    /// Build the config from the stored credentials (nil if incomplete).
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

    /// Check credentials only (login). Returns `nil` on success, else an error text.
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

    /// 3-way merge server ↔ local ↔ last-synced state: add new feeds on both
    /// sides AND propagate unsubscribes. The last-synced state (normalised URLs)
    /// distinguishes "newly subscribed" from "unsubscribed". First run (empty
    /// prior state) = non-destructive union.
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

        // Converged state = present in both + additions on either side. Only
        // SUCCESSFULLY locally subscribed feeds count → failed ones are retried
        // on the next run (instead of being treated as "synced" forever).
        let converged = local.intersection(server).union(addToServer).union(addedLocallyNorms)
        defaults.set(Array(converged), forKey: AppStorageKeys.gpodderLastSyncedFeeds)
        return report
    }

    // MARK: - Real-time push (single episode on play/pause)

    /// Called by the player whenever a podcast episode writes progress
    /// (periodically + on pause/stop/seek). Pushes a single play action to the
    /// server — best effort, does not block playback. `abspod:` episodes are
    /// mapped to their `rss:` counterpart via the feed `guid` bridge (only
    /// possible when the same feed is also subscribed as RSS/gpodder).
    func notePlayback(itemId: String, position: Double, duration: Double) {
        guard AppStorageKeys.gpodderEnabledValue, config != nil else { return }
        let rssId: String?
        if itemId.hasPrefix("rss:") {
            rssId = itemId
        } else if itemId.hasPrefix("abspod:") {
            rssId = ABSPodcastProvider.shared.equivalentIds(itemId).first { $0.hasPrefix("rss:") }
        } else {
            rssId = nil
        }
        guard let rssId else { return }
        Task { await pushSingle(rssItemId: rssId, position: position, duration: duration) }
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

    /// Adopt server play actions into `localPosition` (newer timestamp wins) and
    /// conversely upload positions changed since the last push as play actions.
    /// Matching runs via the (normalised) enclosure URL.
    private func syncEpisodeActions(_ client: GPodderClient) async throws -> (pulled: Int, pushed: Int) {
        let defaults = UserDefaults.standard
        let subs = PodcastSubscriptions.shared

        // Enclosure URL → (rss id, feed URL, duration) across all subscribed episodes.
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

        // --- Push: local → server (only changed since the last push) ---
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
