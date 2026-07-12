import Foundation
import BackgroundTasks
import UserNotifications

/// Background refresh of the podcast sources: fetches feeds + gpodder/ABS sync,
/// notifies about new episodes and triggers auto-download. Registered in
/// `AppDelegate` at launch, (re)scheduled when moving to the background.
@MainActor
enum PodcastRefreshService {
    static let taskId = "de.lzs.ABSPlayer.podcastRefresh"
    private static let lastSeenKey = "podcastLastSeenPub"

    // MARK: - BGTask

    /// Handler registrieren — MUSS vor App-Fertigstart laufen (AppDelegate).
    static func registerBackgroundTask() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: taskId, using: nil) { task in
            let bg = task as? BGAppRefreshTask
            let work = Task { @MainActor in
                await run()
                schedule()
                bg?.setTaskCompleted(success: true)
            }
            bg?.expirationHandler = { work.cancel() }
        }
    }

    /// Request the next background refresh (at earliest in ~4 h; iOS ultimately
    /// decides the timing itself).
    static func schedule() {
        let request = BGAppRefreshTaskRequest(identifier: taskId)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 4 * 3600)
        try? BGTaskScheduler.shared.submit(request)
    }

    // MARK: - Ablauf

    /// Alle Podcast-Quellen aktualisieren, neue Folgen melden, Auto-Download.
    static func run() async {
        await PodcastSubscriptions.shared.refreshAll()
        await GPodderSync.shared.reconcile()
        if AppStorageKeys.absPodcastsEnabledValue { await ABSPodcastProvider.shared.refresh() }
        let shows = dedupedShows()
        await notifyNewEpisodes(shows)
        await PodcastAutoDownload.run(shows: shows)
    }

    /// Cross-source show list (RSS + active ABS), deduplicated by the normalised
    /// feed URL (ABS preferred) — like the podcast home view.
    private static func dedupedShows() -> [PodcastShow] {
        let abs = AppStorageKeys.absPodcastsEnabledValue ? ABSPodcastProvider.shared.activeShows : []
        let absFeeds = Set(abs.map { PodcastSubscriptions.normalizeFeedURL($0.feedURL) })
        let rssOnly = PodcastSubscriptions.shared.shows.filter {
            !absFeeds.contains(PodcastSubscriptions.normalizeFeedURL($0.feedURL))
        }
        return abs + rssOnly
    }

    // MARK: - New-episode notification

    /// Detect new episodes against the last-seen state (per feed) and — if
    /// enabled & allowed — notify. First contact only sets the baseline (no spam
    /// about already-present episodes).
    private static func notifyNewEpisodes(_ shows: [PodcastShow]) async {
        let defaults = UserDefaults.standard
        var lastSeen = (defaults.dictionary(forKey: lastSeenKey) as? [String: Double]) ?? [:]
        let globalOn = AppStorageKeys.podcastNewEpisodeNotificationsEnabled
        // Bundled per show: one message per show instead of one per episode.
        var perShow: [(show: String, count: Int, firstTitle: String)] = []

        for show in shows {
            let key = PodcastSubscriptions.normalizeFeedURL(show.feedURL)
            let newest = show.episodes.map(\.pubDate).max() ?? 0
            // Only notify when enabled globally AND for this show.
            if globalOn, AppStorageKeys.podcastNotifyEnabled(show.id), let seen = lastSeen[key] {
                let news = show.episodes.filter { $0.pubDate > seen }.sorted { $0.pubDate > $1.pubDate }
                if !news.isEmpty {
                    perShow.append((show.title, news.count, news.first?.title ?? ""))
                }
            }
            lastSeen[key] = max(lastSeen[key] ?? 0, newest)
        }
        defaults.set(lastSeen, forKey: lastSeenKey)

        guard !perShow.isEmpty else { return }
        await postNotifications(perShow)
    }

    private static func postNotifications(_ items: [(show: String, count: Int, firstTitle: String)]) async {
        let center = UNUserNotificationCenter.current()
        guard await center.notificationSettings().authorizationStatus == .authorized else { return }
        for it in items {
            let content = UNMutableNotificationContent()
            content.title = it.show
            content.body = it.count == 1 ? it.firstTitle : String(localized: "\(it.count) new episodes")
            content.sound = .default
            try? await center.add(UNNotificationRequest(
                identifier: UUID().uuidString, content: content, trigger: nil))
        }
    }

    /// Benachrichtigungs-Erlaubnis anfragen (beim Aktivieren des Toggles).
    @discardableResult
    static func requestAuthorization() async -> Bool {
        (try? await UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound, .badge])) ?? false
    }
}
