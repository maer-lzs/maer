// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later

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

    /// Register the handler — MUST run before app launch finishes (AppDelegate).
    static func registerBackgroundTask() {
        // Y32: iOS invokes this handler on the BGTaskScheduler queue. Under the
        // project's MainActor default the closure inherited main isolation and
        // the Swift 6 isolation check trapped (EXC_BREAKPOINT) on EVERY
        // background launch — the nightly refresh never actually ran.
        // `@Sendable` makes the closure nonisolated (same contract as the
        // MediaPlayer artwork handler); the work hops to the main actor
        // explicitly, expiration semantics unchanged.
        BGTaskScheduler.shared.register(forTaskWithIdentifier: taskId, using: nil) { @Sendable task in
            let bg = task as? BGAppRefreshTask
            // BGTask's completion/expiration API is documented thread-safe;
            // the reference itself is not Sendable.
            nonisolated(unsafe) let bgTask = bg
            let work = launchWork(
                run: {
                    await run()
                    schedule()
                },
                complete: { success in bgTask?.setTaskCompleted(success: success) })
            bg?.expirationHandler = { @Sendable in work.cancel() }
        }
    }

    /// Y32 (testable core): callable from ANY executor — the scheduler queue in
    /// production, a background task in the test — and hops the refresh work to
    /// the main actor. Always completes (also after a cancel: the work inside
    /// responds cooperatively, the task itself must still report).
    nonisolated static func launchWork(
        run: @escaping @MainActor () async -> Void,
        complete: @escaping @Sendable (Bool) -> Void
    ) -> Task<Void, Never> {
        Task { @MainActor in
            await run()
            complete(true)
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

    /// Refresh all podcast sources, report new episodes, auto-download.
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

    /// Request notification permission (when enabling the toggle).
    @discardableResult
    static func requestAuthorization() async -> Bool {
        (try? await UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound, .badge])) ?? false
    }
}
