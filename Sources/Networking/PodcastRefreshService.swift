import Foundation
import BackgroundTasks
import UserNotifications

/// Hintergrund-Aktualisierung der Podcast-Quellen: lädt Feeds + gpodder/ABS-Sync,
/// benachrichtigt über neue Folgen und stößt Auto-Download an. Registrierung im
/// `AppDelegate` beim Start, (Neu-)Planung beim Wechsel in den Hintergrund.
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

    /// Nächsten Hintergrund-Refresh anfragen (frühestens in ~4 h; iOS entscheidet
    /// letztlich selbst über den Zeitpunkt).
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

    /// Quellen-übergreifende Show-Liste (RSS + aktive ABS), über die normalisierte
    /// Feed-URL dedupliziert (ABS bevorzugt) — wie in der Podcast-Home-Ansicht.
    private static func dedupedShows() -> [PodcastShow] {
        let abs = AppStorageKeys.absPodcastsEnabledValue ? ABSPodcastProvider.shared.activeShows : []
        let absFeeds = Set(abs.map { PodcastSubscriptions.normalizeFeedURL($0.feedURL) })
        let rssOnly = PodcastSubscriptions.shared.shows.filter {
            !absFeeds.contains(PodcastSubscriptions.normalizeFeedURL($0.feedURL))
        }
        return abs + rssOnly
    }

    // MARK: - Neue-Folgen-Benachrichtigung

    /// Neue Folgen gegen den zuletzt gesehenen Stand (je Feed) erkennen und —
    /// falls aktiviert & erlaubt — benachrichtigen. Erstkontakt setzt nur die
    /// Basis (kein Spam über bereits vorhandene Folgen).
    private static func notifyNewEpisodes(_ shows: [PodcastShow]) async {
        let defaults = UserDefaults.standard
        var lastSeen = (defaults.dictionary(forKey: lastSeenKey) as? [String: Double]) ?? [:]
        let notify = AppStorageKeys.podcastNewEpisodeNotificationsEnabled
        var newItems: [(show: String, title: String)] = []

        for show in shows {
            let key = PodcastSubscriptions.normalizeFeedURL(show.feedURL)
            let newest = show.episodes.map(\.pubDate).max() ?? 0
            if notify, let seen = lastSeen[key] {
                for ep in show.episodes where ep.pubDate > seen {
                    newItems.append((show.title, ep.title))
                }
            }
            lastSeen[key] = max(lastSeen[key] ?? 0, newest)
        }
        defaults.set(lastSeen, forKey: lastSeenKey)

        guard notify, !newItems.isEmpty else { return }
        await postNotifications(newItems)
    }

    private static func postNotifications(_ items: [(show: String, title: String)]) async {
        let center = UNUserNotificationCenter.current()
        guard await center.notificationSettings().authorizationStatus == .authorized else { return }

        if items.count <= 3 {
            for it in items {
                let content = UNMutableNotificationContent()
                content.title = it.show
                content.body = it.title
                content.sound = .default
                try? await center.add(UNNotificationRequest(
                    identifier: UUID().uuidString, content: content, trigger: nil))
            }
        } else {
            // Viele auf einmal → eine Sammelmeldung statt Benachrichtigungs-Flut.
            let content = UNMutableNotificationContent()
            content.title = String(localized: "New Episodes")
            content.body = String(localized: "\(items.count) new podcast episodes")
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
