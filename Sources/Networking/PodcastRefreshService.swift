// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation
import BackgroundTasks
import OSLog
import UserNotifications

/// Background refresh of the podcast sources: fetches feeds + gpodder/ABS sync,
/// notifies about new episodes and triggers auto-download. Registered in
/// `AppDelegate` at launch, (re)scheduled when moving to the background.
@MainActor
enum PodcastRefreshService {
    static let taskId = "fm.maer.app.podcastRefresh"
    private static let lastSeenKey = "podcastLastSeenPub"

    // MARK: - BGTask

    /// Register the handler. MUST run before app launch finishes (AppDelegate).
    static func registerBackgroundTask() {
        // iOS invokes this handler on the BGTaskScheduler queue. Under the
        // project's MainActor default the closure inherited main isolation and
        // the Swift 6 isolation check trapped (EXC_BREAKPOINT) on EVERY
        // background launch. The nightly refresh never actually ran.
        // `@Sendable` makes the closure nonisolated (same contract as the
        // MediaPlayer artwork handler); the work hops to the main actor
        // explicitly, expiration semantics unchanged.
        BGTaskScheduler.shared.register(forTaskWithIdentifier: taskId, using: nil) { @Sendable task in
            let bg = task as? BGAppRefreshTask
            // The reference is not Sendable, and the header of `BGTask` says
            // nothing about threads. unsafe because it is used once, by
            // `complete`, which `launchWork` calls on the main actor.
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

    /// Callable from ANY executor. The scheduler queue in
    /// production, a background task in the test. And hops the refresh work to
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
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            // No UI: background scheduling is best-effort (the next foreground
            // run re-schedules). But the failure must not be silent (rule 3).
            Logger.rss.error("BG refresh scheduling failed: \(FailureReason.of(error), privacy: .public)")
        }
    }

    // MARK: - Ablauf

    /// Refresh all podcast sources, report new episodes, auto-download.
    static func run() async {
        await PodcastSubscriptions.shared.refreshAll()
        await GPodderSync.shared.reconcile()
        if AppStorageKeys.absPodcastsActive { await ABSPodcastProvider.shared.refresh() }
        let shows = dedupedShows()
        await notifyNewEpisodes(shows)
        await PodcastAutoDownload.run(shows: shows)
    }

    /// Cross-source show list, each show once. „Like the podcast home view"
    /// is now true because it is the same rule and no longer a copy of it.
    private static func dedupedShows() -> [PodcastShow] { PodcastShowSources.active() }

    // MARK: - New-episode notification

    /// Detect new episodes against the last-seen state (per feed) and. If
    /// enabled & allowed. Notify. First contact only sets the baseline (no spam
    /// about already-present episodes).
    private static func notifyNewEpisodes(_ shows: [PodcastShow]) async {
        var lastSeen = (AppStorageKeys.dictionary(lastSeenKey) as? [String: Double]) ?? [:]
        let globalOn = AppStorageKeys.podcastNewEpisodeNotificationsEnabled
        // Bundled per RUN: the run is the event, so the run gets the message
        // (see NewEpisodeDigest). Per show it was five shows, five messages,
        // five sounds.
        var perShow: [NewEpisodeDigest.Show] = []

        for show in shows {
            let key = PodcastIdentity.normalizeFeedURL(show.feedURL)
            let newest = show.episodes.map(\.pubDate).max() ?? 0
            // Only notify when enabled globally AND for this show.
            if globalOn, AppStorageKeys.podcastNotifyEnabled(show.id), let seen = lastSeen[key] {
                let news = show.episodes.filter { $0.pubDate > seen }.sorted { $0.pubDate > $1.pubDate }
                if !news.isEmpty {
                    perShow.append(NewEpisodeDigest.Show(
                        title: show.title, feedURL: show.feedURL,
                        newCount: news.count,
                        newestEpisodeTitle: news.first?.title ?? ""))
                }
            }
            lastSeen[key] = max(lastSeen[key] ?? 0, newest)
        }
        AppStorageKeys.set(lastSeen, for: lastSeenKey)

        guard let message = NewEpisodeDigest.message(for: perShow) else { return }
        await post(message)
    }

    /// ONE request per run. The identifier is fresh so an earlier message stays
    /// standing; the thread identifier groups them where the reader sees them.
    private static func post(_ message: NewEpisodeDigest.Message) async {
        let center = UNUserNotificationCenter.current()
        guard await center.notificationSettings().authorizationStatus == .authorized else { return }
        let content = UNMutableNotificationContent()
        content.title = message.title
        content.body = message.body
        content.sound = .default
        content.threadIdentifier = NewEpisodeDigest.threadIdentifier
        // The target rides ALONG with the message. The tap must not have to
        // guess what the message was about.
        if case .show(let feedURL) = message.target {
            content.userInfo = [PodcastOpenRequest.feedKey: feedURL]
        }
        try? await center.add(UNNotificationRequest(
            identifier: UUID().uuidString, content: content, trigger: nil))
        Logger.rss.notice("PODCAST notify: one message per run, target=\(String(describing: message.target), privacy: .public)")
    }

    /// Request notification permission (when enabling the toggle).
    @discardableResult
    static func requestAuthorization() async -> Bool {
        (try? await UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound, .badge])) ?? false
    }

    /// What this DEVICE allows. The switch is the person's intent and
    /// travels; the permission is device technique and does not (decided
    /// 07.09.2026). A device that adopted the switch has to ask for
    /// itself, and a refusal is said at the switch instead of silently
    /// sending nothing.
    static func notificationStatus() async -> UNAuthorizationStatus {
        await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }

    /// Asks ONCE per device when the switch is on and nobody has decided
    /// yet. Called where the podcasts surface becomes visible, so the
    /// question appears in the place it belongs to and not at launch.
    static func askForPermissionIfNeeded() async {
        guard AppStorageKeys.podcastNewEpisodeNotificationsEnabled else { return }
        guard await notificationStatus() == .notDetermined else { return }
        let granted = await requestAuthorization()
        Logger.rss.notice("NOTIFY permission asked granted=\(granted)")
        if granted { schedule() }
    }
}
