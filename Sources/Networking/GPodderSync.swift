// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation
import UIKit
import OSLog

/// The two questions the subscription round asks the server, so a witness
/// can stand in for gpodder with a list in memory.
@MainActor
protocol GPodderSubscriptionTransport: AnyObject {
    func subscriptions() async throws -> [String]
    func uploadSubscriptions(add: [String], remove: [String]) async throws
}

extension GPodderClient: GPodderSubscriptionTransport {}

/// Reconciles podcast subscriptions (and later the listening history) with a
/// gpodder-compatible server (oPodSync, Nextcloud GPodder, gpodder.net). On par
/// with iCloud and ABS. Feeds/playback/downloads still go through the
/// `RSSProvider`; this service only syncs the subscription list + `localPosition`.
@MainActor
final class GPodderSync {
    static let shared = GPodderSync()
    private init() {}

    struct Report: Equatable, Codable {
        var addedLocally = 0        // newly subscribed from the server
        var pushedToServer = 0      // local subscriptions pushed to the server
        var historyPulled = 0       // episode positions pulled from the server
        var historyPushed = 0       // episode positions pushed to the server
        /// Subscriptions this run actually REMOVED (possible-data-loss trail).
        var removedLocally = 0      // local unsubscribes applied
        var removedFromServer = 0   // dropped from the server
        /// Human-readable "title — url" of every removed feed (both sides), so
        /// the history entry can name exactly what disappeared.
        var removedFeeds: [String] = []
        var error: String?
        /// Set when the mass-delete guard skipped implausible removes.
        var warning: String?
    }

    /// The last sync outcome, persisted so the settings screen can show it
    /// after an app restart. The mass-delete guard `warning` is STICKY. It
    /// survives until a later CLEAN sync (no warning, no error) clears it, so a
    /// one-off guard trip is not lost the moment the tab is reopened.
    struct StoredReport: Equatable, Codable {
        var date: Date
        var report: Report
        var warning: String?        // sticky guard warning (independent of report.warning)
        var warningDate: Date?
    }

    /// The persisted last sync outcome (loaded once at launch).
    private(set) var storedReport: StoredReport? = StoredReport.load()

    private var isRunning = false
    private static var didAutoReconcile = false

    /// Pure sticky-warning decision (testable): a new warning replaces the old;
    /// a clean sync (no warning, no error) clears it; a failed sync (error, no
    /// warning) keeps the previous warning rather than pretending it's resolved.
    static func stickyWarning(new: Report, previous: StoredReport?, now: Date = Date())
        -> (warning: String?, date: Date?) {
        if let w = new.warning { return (w, now) }
        if new.error == nil { return (nil, nil) }              // clean sync clears it
        return (previous?.warning, previous?.warningDate)      // failed sync keeps it
    }

    /// Persist the outcome of a sync that actually ran.
    private func persist(_ report: Report) {
        let sticky = Self.stickyWarning(new: report, previous: storedReport)
        let stored = StoredReport(date: Date(), report: report,
                                  warning: sticky.warning, warningDate: sticky.date)
        storedReport = stored
        stored.save()
    }

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
        catch { return ErrorSentence.of(error) }
    }

    // MARK: - Manual conflict resolution (guard-blocked divergence)

    /// A fetched local↔server picture for the resolution screen. Normalized keys
    /// (for the pure `GPodderConflictResolution`) + the raw URLs to apply with.
    struct ConflictSnapshot {
        let localNorms: Set<String>
        let serverNorms: Set<String>
        let localRaw: [String: String]    // norm → raw local feed URL
        let serverRaw: [String: String]   // norm → raw server feed URL
    }

    /// Register this device once per deviceId (gpodder API; stricter servers
    /// PodFetch, Pinepods and Nextcloud answer 404 for unknown ids, oPodSync creates them
    /// implicitly). Tolerant in BOTH directions: a failing registration
    /// (server without a devices endpoint) never blocks the sync. Logged,
    /// not silent (rule 3); success is remembered per deviceId so bestehende
    /// users keep their id (never re-rolled) and the call stays one-shot.
    static func ensureDeviceRegistered(_ client: GPodderClient, config: GPodderConfig) async {
        let key = AppStorageKeys.gpodderDeviceRegisteredFor
        guard AppStorageKeys.string(key) != config.deviceId else { return }
        do {
            try await client.registerDevice(caption: Self.deviceCaption())
            AppStorageKeys.set(config.deviceId, for: key)
            Logger.gpodder.notice("gpodder device registered (id kept)")
        } catch {
            // Server without a devices endpoint (or transient). Sync must
            // proceed; retry naturally on the next run.
            Logger.gpodder.error("gpodder device registration failed (sync continues): \(FailureReason.of(error), privacy: .public)")
        }
    }

    /// The user-facing device name as the registration caption.
    static func deviceCaption() -> String {
        #if canImport(UIKit)
        return UIDevice.current.name.isEmpty ? "Maer" : UIDevice.current.name
        #else
        return "Maer"
        #endif
    }

    /// Fetch the current server + local subscriptions for the resolution UI.
    /// nil when not configured or the server can't be reached.
    func conflictSnapshot() async -> ConflictSnapshot? {
        guard let config else { return nil }
        let client = GPodderClient(config: config)
        guard (try? await client.login()) != nil,
              let serverURLs = try? await client.subscriptions() else { return nil }
        let localRaw = GPodderVisibleSubscriptions.current().byNorm
        return Self.conflictSnapshot(serverURLs: serverURLs, localRaw: localRaw,
                                     premiumOptIn: AppStorageKeys.gpodderSyncsPremiumFeedsEnabled,
                                     leftOnServer: GPodderVisibleSubscriptions.currentLeftOnServer(local: Set(localRaw.keys)))
    }

    /// The snapshot from the server's list: the server side through the
    /// same visibility as the round (`visibleServerURLs`), so the sheet sees
    /// neither the feeds left on the server nor, without the opt-in, the
    /// token feeds.
    static func conflictSnapshot(serverURLs: [String], localRaw: [String: String],
                                 premiumOptIn: Bool, leftOnServer: Set<String>) -> ConflictSnapshot {
        let serverRaw = GPodderVisibleSubscriptions.visibleServerURLs(
            Dictionary(serverURLs.map { (PodcastSubscriptions.normalizeFeedURL($0), $0) }, uniquingKeysWith: { a, _ in a }),
            premiumOptIn: premiumOptIn, leftOnServer: leftOnServer)
        return ConflictSnapshot(localNorms: Set(localRaw.keys), serverNorms: Set(serverRaw.keys),
                                localRaw: localRaw, serverRaw: serverRaw)
    }

    /// Apply the user's resolution via the EXISTING building blocks (no parallel
    /// sync path): push/remove on the server, subscribe/unsubscribe locally, set
    /// the converged `gpodderLastSyncedFeeds`, and CLEAR the sticky guard warning
    /// so the next `reconcile()` doesn't immediately re-fire it for feeds the
    /// user just resolved. Returns an error text or nil.
    func applyConflictResolution(_ actions: GPodderConflictResolution.Actions,
                                 snapshot: ConflictSnapshot) async -> String? {
        guard let config else { return String(localized: "Please fill in server, username and password.") }
        return await applyConflictResolution(actions, snapshot: snapshot) { add, remove in
            let client = GPodderClient(config: config)
            try await client.login()
            try await client.uploadSubscriptions(add: add, remove: remove)
        }
    }

    /// The same, with the server's one request as a seam. While gpodder
    /// rests it changes nothing and says why: resolving would take the
    /// feeds of the account before into this one, or remove them.
    func applyConflictResolution(_ actions: GPodderConflictResolution.Actions, snapshot: ConflictSnapshot,
                                 rest: GPodderRest = GPodderSync.rest(on: MaerDatabase.restingShelf),
                                 upload: (_ add: [String], _ remove: [String]) async throws -> Void) async -> String? {
        if let sentence = rest.sentence { return sentence }
        let subs = PodcastSubscriptions.shared
        // Server side (one request): push kept local-only, remove dropped server-only.
        let add = actions.addToServer.compactMap { snapshot.localRaw[$0] }
        let remove = actions.removeFromServer.compactMap { snapshot.serverRaw[$0] }
        if !add.isEmpty || !remove.isEmpty {
            do { try await upload(add, remove) }
            catch { return ErrorSentence.of(error) }
        }
        // Local side. Only a show subscribed here counts as synced, as in
        // the ordinary round: one set out, held on Audiobookshelf or not
        // subscribed is not here, and counted as synced its absence would
        // read as a removal toward the server next round.
        var subscribed: Set<String> = []
        var setOut = 0
        for norm in actions.subscribeLocally {
            // The person resolved the conflict, and what stays is noted to
            // the family like every other applied change of the round.
            guard let raw = snapshot.serverRaw[norm] else { continue }
            switch await subs.subscribeUnlessOnServer(urlString: raw, notesCloud: true, isSingleUserAct: false) {
            case .subscribed, .subscribedUnchecked: subscribed.insert(norm)
            case .setOut: setOut += 1
            case .onServer, .notSubscribed: break
            }
        }
        // Audiobookshelf could not be read: those shows were not added here,
        // and the person hears it through the one notice the badge uses.
        if setOut > 0 {
            Logger.rss.notice("GPODDER resolution: subscriptions set out, Audiobookshelf unread count=\(setOut)")
            subs.serverUnreadNotice = true
        }
        let notHere = actions.subscribeLocally.count - subscribed.count
        if notHere > 0 {
            Logger.rss.notice("GPODDER resolution: taken from the server but not subscribed here count=\(notHere), not counted as synced")
        }
        for norm in actions.unsubscribeLocally {
            if let show = subs.shows.first(where: { PodcastSubscriptions.normalizeFeedURL($0.feedURL) == norm }) {
                // A server drop travels as the person's unsubscribe made on
                // another client; the feed's stands stay.
                subs.unsubscribe(id: show.id, notesCloud: true)
            }
        }
        AppStorageKeys.set(Array(GPodderConflictResolution.synced(actions, subscribed: subscribed)),
                           for: AppStorageKeys.gpodderLastSyncedFeeds)
        clearGuardWarning()
        return nil
    }

    /// Drop the sticky guard warning (keeps the last-sync counts/date).
    func clearGuardWarning() {
        guard let stored = storedReport, stored.warning != nil else { return }
        let cleared = StoredReport(date: stored.date, report: stored.report, warning: nil, warningDate: nil)
        storedReport = cleared
        cleared.save()
    }

    /// Whether gpodder may run (`GPodderRest.runs`).
    static func followsTheSubscriptions(on shelf: RestingShelf?, quietly: Bool = false) -> Bool {
        rest(on: shelf, quietly: quietly) == .runs
    }

    /// Whether gpodder runs or rests, and why: its account belongs to the
    /// device, not to the sync account. After a change of account its round
    /// would take the feeds of the account before from its server into the
    /// new account's subscriptions, so it rests while another account holds
    /// them than the one it ran for (`RestingShelf.follows`), until the
    /// person goes on with this account or disconnects gpodder. A shelf that
    /// cannot be read rests it too. The player asks on every tick, so the
    /// line of an unreadable shelf comes once per state (`GPodderRestLog`),
    /// not once per question.
    static func rest(on shelf: RestingShelf?, quietly: Bool = false) -> GPodderRest {
        guard let shelf else {
            _ = restLog.due(.runs)
            return .runs
        }
        do {
            guard try shelf.follows(shelfFamily, holderOf: PodcastSubscriptions.shelfFamily) else {
                if !quietly {
                    Logger.gpodder.notice("GPODDER rests: the subscriptions belong to another account than the one it ran for")
                }
                _ = restLog.due(.restsAfterSwitch)
                return .restsAfterSwitch
            }
            _ = restLog.due(.runs)
            return .runs
        } catch {
            if restLog.due(.ownerUnreadable) {
                Logger.gpodder.error("GPODDER rests: owner unreadable reason=\(String(describing: error), privacy: .public)")
            }
            return .ownerUnreadable
        }
    }

    /// What `rest(on:quietly:)` last answered, for the one line of an
    /// unreadable shelf.
    private(set) static var restLog = GPodderRestLog()

    #if DEBUG
    /// Witnesses start from a gpodder that runs.
    static func testResetRestLog() { restLog = GPodderRestLog() }
    #endif

    /// gpodder's name on the shelf, where it follows the subscriptions.
    static let shelfFamily = "gpodder"

    /// Goes on with the account that holds the subscriptions now. The feeds
    /// only on the gpodder server came from the account before: they stay
    /// there, never taken into this account and never removed from the
    /// server (`GPodderVisibleSubscriptions.withoutLeftOnServer`). The
    /// prior state becomes what both sides share, so this account's own
    /// feeds go to the server on the next round. gpodder follows the holder
    /// only once that is written; an error leaves the rest standing.
    func continueWithThisAccount() async -> String? {
        guard let config else { return String(localized: "Please fill in server, username and password.") }
        let client = GPodderClient(config: config)
        do {
            try await client.login()
            let serverURLs = try await client.subscriptions()
            return continueWithThisAccount(serverURLs: serverURLs, shelf: MaerDatabase.restingShelf)
        } catch {
            return ErrorSentence.of(error)
        }
    }

    /// The same, with the server's list handed in.
    func continueWithThisAccount(serverURLs: [String], shelf: RestingShelf?) -> String? {
        let server = Set(serverURLs.map(PodcastSubscriptions.normalizeFeedURL))
        let local = Set(GPodderVisibleSubscriptions.current().byNorm.keys)
        let left = GPodderVisibleSubscriptions.leftOnServer(server: server, local: local)
        // The holder first: it can fail, the keys cannot. A failed holder
        // leaves gpodder resting with the state of the account before, so a
        // return of that account goes on with its own state.
        do {
            try shelf?.adopt(Self.shelfFamily, holderOf: PodcastSubscriptions.shelfFamily)
        } catch {
            Logger.gpodder.error("GPODDER continue: holder not written reason=\(String(describing: error), privacy: .public)")
            return ErrorSentence.of(error)
        }
        AppStorageKeys.set(Array(left), for: AppStorageKeys.gpodderLeftOnServer)
        AppStorageKeys.set(Array(local.intersection(server)), for: AppStorageKeys.gpodderLastSyncedFeeds)
        AppStorageKeys.remove(AppStorageKeys.gpodderPendingRemoveLocal)
        AppStorageKeys.remove(AppStorageKeys.gpodderPendingRemoveServer)
        Logger.gpodder.notice("GPODDER continues with this account: left on the server=\(left.count) shared=\(local.intersection(server).count)")
        return nil
    }

    /// Signs this device out of gpodder: address, name, password and the
    /// state of the rounds go; nothing changes on the gpodder server. gpodder
    /// then follows the account that holds the subscriptions, so a new
    /// sign-in starts as a first one.
    func disconnect(shelf: RestingShelf? = MaerDatabase.restingShelf) {
        for key in [AppStorageKeys.gpodderServerURL, AppStorageKeys.gpodderUsername,
                    AppStorageKeys.gpodderLastSyncedFeeds, AppStorageKeys.gpodderPendingRemoveLocal,
                    AppStorageKeys.gpodderPendingRemoveServer, AppStorageKeys.gpodderLeftOnServer,
                    AppStorageKeys.gpodderDeviceRegisteredFor] {
            AppStorageKeys.remove(key)
        }
        AppStorageKeys.setGpodderPassword("")
        do {
            try shelf?.adopt(Self.shelfFamily, holderOf: PodcastSubscriptions.shelfFamily)
        } catch {
            Logger.gpodder.error("GPODDER disconnect: holder not written reason=\(String(describing: error), privacy: .public)")
        }
        Logger.gpodder.notice("GPODDER disconnected on this device, the server unchanged")
    }

    /// Reconcile subscriptions (and history – part 2). Idempotent, never two at once.
    @discardableResult
    func reconcile() async -> Report {
        var report = Report()
        guard !isRunning else { return report }
        guard AppStorageKeys.gpodderEnabledValue, let config else { return report }
        guard Self.followsTheSubscriptions(on: MaerDatabase.restingShelf) else { return report }
        let signpost = PerfSignpost.syncRound(.gpodder, .server)
        defer { signpost.end() }
        isRunning = true
        defer { isRunning = false }
        let syncStarted = Date()

        let client = GPodderClient(config: config)
        do {
            try await client.login()
            await Self.ensureDeviceRegistered(client, config: config)
            do {
                report = try await syncSubscriptions(client)
            } catch {
                // A device-scoped endpoint rejecting the id (strict server,
                // registration lost): register once and retry. Never report
                // the sync as broken for a recoverable device state.
                Logger.gpodder.notice("gpodder sync retry after device (re)registration")
                AppStorageKeys.remove(AppStorageKeys.gpodderDeviceRegisteredFor)
                await Self.ensureDeviceRegistered(client, config: config)
                report = try await syncSubscriptions(client)
            }
            let hist = try await syncEpisodeActions(client)
            report.historyPulled = hist.pulled
            report.historyPushed = hist.pushed
        } catch {
            report.error = ErrorSentence.of(error)
        }
        persist(report)   // survive an app restart + keep a guard warning sticky
        // A run that CHANGED something, failed or tripped a guard lands
        // as a ring entry (a guard becomes a PERMANENT marked entry); a clean
        // no-op run only bumps the "last checked" stamp, so the ring stays
        // meaningful.
        // A removal (even a single "plausible" one) MUST create a visible entry.
        // That was the silent data-loss gap. Removals count as "changed".
        let changed = report.addedLocally > 0 || report.pushedToServer > 0
            || report.historyPulled > 0 || report.historyPushed > 0
            || report.removedLocally > 0 || report.removedFromServer > 0
        SyncHistoryStore.shared.record(SyncHistory.entry(
            service: .gpodder, direction: .both,
            counters: [.init(key: .subscriptionsDown, value: report.addedLocally),
                       .init(key: .subscriptionsUp, value: report.pushedToServer),
                       .init(key: .subscriptionsRemovedLocally, value: report.removedLocally),
                       .init(key: .subscriptionsRemovedFromServer, value: report.removedFromServer),
                       .init(key: .positionsDown, value: report.historyPulled),
                       .init(key: .positionsUp, value: report.historyPushed)],
            duration: Date().timeIntervalSince(syncStarted),
            error: report.error, guardNote: report.warning,
            removedFeeds: report.removedFeeds,
            deviceId: SyncHistoryStore.deviceId, startedAt: syncStarted),
            moved: changed || report.error != nil || report.warning != nil)
        return report
    }

    /// Once per app session automatically, if enabled & configured.
    func autoReconcileIfNeeded() async {
        guard !Self.didAutoReconcile, AppStorageKeys.gpodderEnabledValue, config != nil else { return }
        Self.didAutoReconcile = true
        await reconcile()
    }

    // MARK: - Subscription sync (union merge, non-destructive)

    /// 3-way merge server ↔ local ↔ last-synced state: add new feeds on both
    /// sides AND propagate unsubscribes. The last-synced state (normalised URLs)
    /// distinguishes "newly subscribed" from "unsubscribed". First run (empty
    /// prior state) = non-destructive union.
    func syncSubscriptions(_ client: any GPodderSubscriptionTransport) async throws -> Report {
        var report = Report()
        let subs = PodcastSubscriptions.shared

        let serverURLs = try await client.subscriptions()
        let serverByNorm = Dictionary(serverURLs.map { (PodcastSubscriptions.normalizeFeedURL($0), $0) },
                                      uniquingKeysWith: { a, _ in a })
        // The ONE source of "which local subscriptions does gpodder see"
        // (see GPodderVisibleSubscriptions): this comparison set used to
        // carry only HALF the rule. The mirror exclusion its own comment
        // promised was missing, so every capsule-carrying device pushed the
        // mirror URLs and mesh-less devices inherited them as dead feeds.
        let visible = GPodderVisibleSubscriptions.current()
        let localByNorm = visible.byNorm
        // The SERVER side goes through the SAME visibility source.
        // With the opt-in off, token feeds are invisible in both directions
        // (neither adopted nor cleaned up), otherwise the asymmetry becomes
        // a tug-of-war between two devices.
        let visibleServerByNorm = GPodderVisibleSubscriptions.visibleServerURLs(
            serverByNorm, premiumOptIn: AppStorageKeys.gpodderSyncsPremiumFeedsEnabled,
            leftOnServer: GPodderVisibleSubscriptions.currentLeftOnServer(local: Set(localByNorm.keys)))
        let prev = Set(AppStorageKeys.stringArray(AppStorageKeys.gpodderLastSyncedFeeds) ?? [])
        // 2–3-feed removals awaiting their second confirmation (from last run).
        let prevPendingLocal = Set(AppStorageKeys.stringArray(AppStorageKeys.gpodderPendingRemoveLocal) ?? [])
        let prevPendingServer = Set(AppStorageKeys.stringArray(AppStorageKeys.gpodderPendingRemoveServer) ?? [])

        let local = Set(localByNorm.keys)
        let server = Set(visibleServerByNorm.keys)

        // Pure 3-way merge WITH mass-delete guard. An implausible server
        // answer must not wipe the local subscription list. 2–3-feed removals
        // additionally need a second consecutive confirmation before applying.
        let merge = GPodderSubscriptionMerge.compute(
            local: local, server: server, prev: prev,
            pendingRemoveLocally: prevPendingLocal, pendingRemoveFromServer: prevPendingServer,
            userRemovedLocally: PodcastSubscriptions.userRemovedFeeds(),
            hiddenLocally: visible.hiddenNorms)
        if merge.recoveredFromServer {
            Logger.gpodder.error("gpodder RECOVERY: local store empty, prev=\(prev.count) server=\(server.count) — adopting the server wholesale (pull only)")
        }
        // Persist the held (not-yet-confirmed) removals for the next run.
        AppStorageKeys.set(Array(merge.pendingRemoveLocally), for: AppStorageKeys.gpodderPendingRemoveLocal)
        AppStorageKeys.set(Array(merge.pendingRemoveFromServer), for: AppStorageKeys.gpodderPendingRemoveServer)
        for norm in merge.pendingRemoveLocally.union(merge.pendingRemoveFromServer) {
            Logger.gpodder.warning("gpodder removal PENDING (awaiting 2nd sync): url=\(PodcastSubscriptions.maskedFeedURL(norm), privacy: .public) side=\(merge.pendingRemoveLocally.contains(norm) ? "local" : "server", privacy: .public)")
        }
        if let warning = merge.warning {
            report.warning = warning
            Logger.gpodder.warning("subscription sync guard: \(warning, privacy: .public)")
        }

        // Log-First (possible data loss): record EVERY removal. Applied or
        // guard-blocked. With its normalised url, side and prior-state
        // membership, so a suspected subscription loss can be reconstructed.
        // The guard threshold is deliberately UNCHANGED here.
        for norm in merge.blockedRemoveLocally.union(merge.blockedRemoveFromServer) {
            Logger.gpodder.warning("gpodder removal BLOCKED (guard): url=\(PodcastSubscriptions.maskedFeedURL(norm), privacy: .public) side=\(merge.blockedRemoveLocally.contains(norm) ? "local" : "server", privacy: .public) inPrev=\(prev.contains(norm))")
        }

        // Server side: add + remove in one request.
        if !merge.addToServer.isEmpty || !merge.removeFromServer.isEmpty {
            try await client.uploadSubscriptions(
                add: merge.addToServer.compactMap { localByNorm[$0] },
                remove: merge.removeFromServer.compactMap { visibleServerByNorm[$0] }
            )
            report.pushedToServer = merge.addToServer.count
            // Applied user-intent removes are consumed (one-shot).
            PodcastSubscriptions.consumeUserRemovedFeeds(merge.removeFromServer)
            for norm in merge.removeFromServer {
                let raw = visibleServerByNorm[norm] ?? norm
                report.removedFromServer += 1
                report.removedFeeds.append(PodcastSubscriptions.maskedFeedURL(raw))
                Logger.gpodder.warning("gpodder removal APPLIED (server): url=\(PodcastSubscriptions.maskedFeedURL(raw), privacy: .public) inPrev=\(prev.contains(norm))")
            }
        }
        // Local side: subscribe to new feeds, remove unsubscribed ones. Both
        // are NOTED to the account's family: what gpodder holds is what the
        // person decided on some client, and the family and the server say
        // the same thing (a device without a server follows the family, a
        // device with one applies the family and hands it to the server).
        // Left unnoted, a server drop came back through the family: the
        // statement of the subscription outlived the drop and was adopted
        // again on the next reconcile, then pushed to the server once more.
        var addedLocallyNorms = Set<String>()
        for norm in merge.addLocally {
            if let raw = visibleServerByNorm[norm],
               await subs.subscribeUnlessOnServer(urlString: raw, notesCloud: true, isSingleUserAct: false) == .subscribed {
                report.addedLocally += 1
                addedLocallyNorms.insert(norm)
            }
        }
        for norm in merge.removeLocally {
            if let show = subs.shows.first(where: { PodcastSubscriptions.normalizeFeedURL($0.feedURL) == norm }) {
                report.removedLocally += 1
                let title = show.title.isEmpty ? show.feedURL : show.title
                report.removedFeeds.append("\(title) · \(PodcastSubscriptions.maskedFeedURL(show.feedURL))")
                Logger.gpodder.warning("gpodder removal APPLIED (local): title=\(title, privacy: .public) url=\(PodcastSubscriptions.maskedFeedURL(show.feedURL), privacy: .public) inPrev=\(prev.contains(norm))")
                // A server drop travels as the person's unsubscribe made on
                // another client; the feed's stands stay.
                subs.unsubscribe(id: show.id, notesCloud: true)
            }
        }

        // Converged state = present in both + additions on either side. Only
        // SUCCESSFULLY locally subscribed feeds count → failed ones are retried
        // on the next run. When the guard fired, the prior state stays UNTOUCHED
        // (updating it would re-push the survivors as "newly subscribed" and
        // hide the incident).
        if merge.mayUpdatePrevState {
            let converged = local.intersection(server).union(merge.addToServer).union(addedLocallyNorms)
            AppStorageKeys.set(Array(converged), for: AppStorageKeys.gpodderLastSyncedFeeds)
        }
        return report
    }

    // MARK: - Real-time push (single episode on play/pause)

    /// Called by the player whenever a podcast episode writes progress
    /// (periodically + on pause/stop/seek). Pushes a single play action to the
    /// server. Best effort, does not block playback. `abspod:` episodes are
    /// mapped to their `rss:` counterpart via the feed `guid` bridge (only
    /// possible when the same feed is also subscribed as RSS/gpodder).
    /// Per-episode throttle for the real-time push: the rule's, so a failed
    /// push can take its mark back instead of eating the next one's window.
    private var realtimeThrottle = GPodderPushRules.Throttle()

    func notePlayback(itemId: String, position: Double, duration: Double) {
        guard AppStorageKeys.gpodderEnabledValue, config != nil else { return }
        // The same rest as the round: a playback under another account than
        // the one gpodder ran for pushes nothing to its server. Quiet, the
        // player asks on every tick.
        guard Self.followsTheSubscriptions(on: MaerDatabase.restingShelf, quietly: true) else { return }
        let rssId: String?
        if ItemNamespace.isRSS(itemId) {
            rssId = itemId
        } else if ItemNamespace.isABSPodcast(itemId) {
            rssId = ABSPodcastProvider.shared.equivalentIds(itemId).first(where: ItemNamespace.isRSS)
        } else {
            rssId = nil
        }
        guard let rssId else { return }
        // Coalesce: skip if the same episode was just pushed at a near-identical
        // position (rapid ticks/seeks). The periodic reconcile still catches any
        // dropped update via the last-push cursor, so nothing is lost.
        let nowMs = Date().timeIntervalSince1970 * 1000
        let posInt = Int(position)
        guard realtimeThrottle.shouldPush(rssId, position: posInt, nowMs: nowMs) else { return }
        realtimeThrottle.noteAttempt(rssId, position: posInt, nowMs: nowMs)
        Task { await pushSingle(rssItemId: rssId, position: position, duration: duration, attemptedAtMs: nowMs) }
    }

    private func pushSingle(rssItemId: String, position: Double, duration: Double, attemptedAtMs: Double) async {
        guard let config,
              let found = PodcastSubscriptions.shared.episode(guid: rssItemId) else { return }
        let total = duration > 0 ? duration : found.episode.duration
        // The action carries the EVENT's timestamp (the stored
        // entry's), not the push moment. The batch push further down has
        // always done it this way; this single push was the exception. And a
        // push-time stamp is how old knowledge travels dressed as new: any
        // re-push of an old position would outvote a younger finished mark on
        // every other device. During real playback the entry was written
        // moments ago, so nothing changes there.
        let entryTs = ListeningStore.backup(rssItemId).flatMap { $0.count >= 2 ? $0[1] : nil }
            ?? Date().timeIntervalSince1970 * 1000
        let action: [String: Any] = [
            "podcast": found.show.feedURL,
            "episode": found.episode.audioURL,
            "device": config.deviceId,
            "action": "play",
            "timestamp": Self.isoTimestamp(entryTs),
            "started": 0,
            "position": Int(position),
            "total": Int(total)
        ]
        do {
            _ = try await GPodderClient(config: config).uploadEpisodeActions([action])
        } catch {
            // Not silent: the position is not lost (the batch push carries
            // it after the cursor), but a failure that leaves no line is how
            // a dead server goes unnoticed for weeks. And the attempt's mark
            // is taken back, so the next tick is not held for a push that
            // never landed.
            Logger.library.notice("GPODDER realtime push failed reason=\(String(describing: error), privacy: .public); the batch carries it")
            realtimeThrottle.noteFailure(rssItemId, position: Int(position), nowMs: attemptedAtMs)
        }
    }

    // MARK: - History sync (episode actions ↔ localPosition)

    /// Adopt server play actions into `localPosition` (newer timestamp wins) and
    /// conversely upload positions changed since the last push as play actions.
    /// Matching runs via the (normalised) enclosure URL.
    private func syncEpisodeActions(_ client: GPodderClient) async throws -> (pulled: Int, pushed: Int) {
        let subs = PodcastSubscriptions.shared

        // Enclosure URL → (rss id, feed URL, duration) across all subscribed episodes.
        var byEnclosure: [String: (id: String, feed: String, duration: Double)] = [:]
        for (show, ep) in subs.allEpisodes() {
            byEnclosure[PodcastSubscriptions.normalizeEnclosure(ep.audioURL)] =
                (ep.guid, show.feedURL, ep.duration)
        }

        // --- Pull: server → local ---
        // The account this round writes for, taken before the network: a
        // change of account while the actions load or merge leaves this
        // round writing nothing into the new account's stock.
        let epoch = ListeningStore.ownerEpoch()
        let since = AppStorageKeys.int(AppStorageKeys.gpodderEpisodeSince) ?? 0
        let (actions, newSince) = try await client.episodeActions(since: since)
        // Cheap main-actor pass first: matching over the index and the
        // timestamp parse (the shared formatters live on this actor).
        // No store access here.
        let plays: [(guid: String, pos: Int, tsMs: Double, total: Double)] =
            actions.compactMap { a in
                guard a.action?.lowercased() == "play",
                      let enc = a.episode, let pos = a.position,
                      let match = byEnclosure[PodcastSubscriptions.normalizeEnclosure(enc)],
                      let tsMs = Self.parseTimestamp(a.timestamp) else { return nil }
                return (match.id, pos, tsMs, Double(a.total ?? 0))
            }
        // The store loop runs OFF the main actor. A fresh sign-in replays
        // the WHOLE action history, and per action this touches the
        // defaults store several times; on main those reads and writes,
        // plus the pending KVO delivery they queue, were exactly where the
        // watchdog found the app after ten seconds. ListeningStore and
        // ProgressMark are nonisolated by design; the stores' UI
        // notifications hop back afterwards, once.
        // detached because the merge is CPU work off the MainActor
        let outcome = await Task.detached(priority: .userInitiated) {
            () -> (pulledGuids: [String], supplemented: Int, accountChanged: Bool) in
            var pulledGuids: [String] = []
            var supplemented = 0
            for play in plays {
                if ListeningStore.ownerEpoch() != epoch { return (pulledGuids, supplemented, true) }
                // Read and write as one under the stock's lock: a position
                // the player writes meanwhile is the entry the rule decides on.
                var path: GPodderMergePath?
                ListeningStore.merge(play.guid, epoch: epoch) { localArr in
                    path = GPodderMergePath.of(local: localArr, serverTsMs: play.tsMs, serverTotal: play.total)
                    switch path {
                    case .adopt:
                        // PATH 1. ADOPTION: the server is newer, its state wins.
                        // `advancing` rather than `entry`: when the server reports
                        // no `total`, the existing reference point must NOT die.
                        // That is how a background sync replaced good three-value
                        // marks with two-value ones. In the worst case with a
                        // device's own echo, because the push stamps the moment of
                        // pushing.
                        return ProgressMark.advancing(localArr, position: Double(play.pos),
                                                      duration: play.total, nowMs: play.tsMs)
                    case .supplement(let healed):
                        // PATH 2. SUPPLEMENT: the local entry is correct, it only
                        // lacks its reference point. This is NOT an adoption, so it
                        // has nothing to do with timestamps. For the affected
                        // episodes both sides stem from the SAME event and the
                        // server is never newer. Only the duration is added;
                        // position and timestamp stay untouched, and no entry is
                        // ever created from nothing.
                        return healed
                    case nil:
                        return nil
                    }
                }
                switch path {
                case .adopt: pulledGuids.append(play.guid)
                case .supplement: supplemented += 1
                case nil: break
                }
            }
            return (pulledGuids, supplemented, ListeningStore.ownerEpoch() != epoch)
        }.value
        if outcome.accountChanged {
            Logger.rss.notice("GPODDER round stopped writing: the account changed while it ran, applied=\(outcome.pulledGuids.count + outcome.supplemented) of=\(plays.count)")
            return (0, 0)
        }
        let pulled = outcome.pulledGuids.count
        AppStorageKeys.set(newSince, for: AppStorageKeys.gpodderEpisodeSince)
        if outcome.supplemented > 0 {
            Logger.rss.notice("GPODDER supplemented \(outcome.supplemented) entries with the duration they were written against")
        }
        if pulled > 0 {
            PodcastProgressStore.shared.reload()   // trigger UI + iCloud reconcile
            PodcastCloudSync.shared.reconcile()
            // Personen-Ebene: gpodder-applied transitions feed the log,
            // gathered ONCE and chunked so the main actor breathes between
            // chunks instead of standing for the whole history.
            await PodcastListenLog.shared.noteReconciled(batched: outcome.pulledGuids)
        }

        // --- Push: local → server (only changed since the last push) ---
        let lastPush = AppStorageKeys.double(AppStorageKeys.gpodderLastEpisodePush) ?? 0
        // The moment the batch is GATHERED is where the cursor goes after
        // the push, not the moment of writing it: a position written while
        // the batch was on its way used to fall between the two and was
        // never after the cursor again.
        let gatheredAt = Date().timeIntervalSince1970
        // Same split as the pull: the store reads over EVERY episode leave
        // the main actor (a big library pays one defaults read per episode
        // here), the candidates come back as values, and the payload
        // assembly with the actor-bound formatter stays on main; the few
        // survivors of the threshold cost microseconds to format.
        let candidates: [(feed: String, audioURL: String, guid: String, duration: Double)] =
            subs.allEpisodes().map { (show, ep) in (show.feedURL, ep.audioURL, ep.guid, ep.duration) }
        // detached because the match is CPU work off the MainActor
        let changed = await Task.detached(priority: .userInitiated) {
            () -> [(feed: String, audioURL: String, pos: Double, tsMs: Double, duration: Double)] in
            return candidates.compactMap { c in
                guard let arr = ListeningStore.backup(c.guid), arr.count >= 2,
                      GPodderPushRules.isAfterCursor(entryMs: arr[1], cursorSeconds: lastPush) else { return nil }
                return (c.feed, c.audioURL, arr[0], arr[1], c.duration)
            }
        }.value
        var out: [[String: Any]] = []
        for entry in changed {
            out.append([
                "podcast": entry.feed,
                "episode": entry.audioURL,
                "device": config?.deviceId ?? "",
                "action": "play",
                "timestamp": Self.isoTimestamp(entry.tsMs),
                "started": 0,
                "position": Int(entry.pos),
                "total": Int(entry.duration)
            ])
        }
        if !out.isEmpty {
            _ = try await client.uploadEpisodeActions(out)
            AppStorageKeys.set(GPodderPushRules.cursorAfterPush(gatheredAtSeconds: gatheredAt),
                               for: AppStorageKeys.gpodderLastEpisodePush)
        }
        return (pulled, out.count)
    }

    // MARK: - Timestamps (gpodder uses ISO 8601 without time zone, UTC)

    private static let iso: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        return f
    }()
    private static let isoFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let iso8601 = ISO8601DateFormatter()

    /// "2009-12-12T09:00:00" → ms since 1970 (UTC). Returns nil when the timestamp
    /// is missing or unparseable. The caller then SKIPS the action rather than
    /// assuming "now", which would wrongly beat a newer local position and clobber
    /// real progress. Also tolerates fractional seconds and explicit zone offsets.
    private static func parseTimestamp(_ s: String?) -> Double? {
        guard let s, !s.isEmpty else { return nil }
        let hasZone = s.hasSuffix("Z")
            || s.range(of: #"[+-]\d\d:?\d\d$"#, options: .regularExpression) != nil
        let normalized = hasZone ? s : s + "Z"
        if let d = isoFractional.date(from: normalized) { return d.timeIntervalSince1970 * 1000 }
        if let d = iso8601.date(from: normalized) { return d.timeIntervalSince1970 * 1000 }
        // Legacy fixed formatter (no zone designator).
        let clean = s.hasSuffix("Z") ? String(s.dropLast()) : s
        if let d = iso.date(from: clean) { return d.timeIntervalSince1970 * 1000 }
        return nil
    }

    private static func isoTimestamp(_ ms: Double) -> String {
        iso.string(from: Date(timeIntervalSince1970: ms / 1000))
    }
}

extension GPodderSync.StoredReport {
    private static let key = "gpodderLastReport"

    static func load() -> GPodderSync.StoredReport? {
        guard let data = AppStorageKeys.data(key) else { return nil }
        return try? JSONDecoder().decode(GPodderSync.StoredReport.self, from: data)
    }

    func save() {
        guard let data = try? JSONEncoder().encode(self) else { return }
        AppStorageKeys.set(data, for: Self.key)
    }
}

/// What a pulled play action does to the local entry: the server is newer
/// and wins (adopt), or the local entry is right and only lacks the
/// duration it was written against (supplement), or nothing. Decided from
/// the entry as it stands, inside `ListeningStore.merge`.
nonisolated enum GPodderMergePath: Equatable, Sendable {
    case adopt
    case supplement([Double])

    static func of(local: [Double]?, serverTsMs: Double, serverTotal: Double) -> GPodderMergePath? {
        let localTs = (local?.count ?? 0) >= 2 ? local![1] : -1
        if serverTsMs > localTs { return .adopt }
        if let local, let healed = ProgressMark.supplementing(local, duration: serverTotal) { return .supplement(healed) }
        return nil
    }
}

/// Whether gpodder runs, and if not, why. Read at one place
/// (`GPodderSync.rest`); the round, the playback push, the conflict path and
/// the settings ask it.
nonisolated enum GPodderRest: Equatable, Sendable {
    case runs
    /// Another account holds the subscriptions than the one gpodder ran for.
    case restsAfterSwitch
    /// Whose the subscriptions are cannot be read.
    case ownerUnreadable

    /// What the person reads while gpodder rests; nil while it runs.
    var sentence: String? {
        switch self {
        case .runs:
            return nil
        case .restsAfterSwitch:
            return String(localized: "gpodder is paused: your subscriptions now belong to a different account. This device is still signed in to the same gpodder account as before.")
        case .ownerUnreadable:
            return String(localized: "gpodder is paused: it cannot be read which account the subscriptions belong to.")
        }
    }
}

/// When the line of an unreadable shelf is due: when the answer before was
/// another. Ten ticks over a shelf that stays unreadable write one line; a
/// shelf that reads again and then fails again writes the next.
nonisolated struct GPodderRestLog: Equatable, Sendable {
    private(set) var last: GPodderRest = .runs
    /// How many unreadable lines came due, for the witnesses.
    private(set) var lines = 0

    /// Remembers `state`; true when it is an unreadable shelf after another
    /// answer, the moment its line is written.
    mutating func due(_ state: GPodderRest) -> Bool {
        defer { last = state }
        guard state == .ownerUnreadable, last != .ownerUnreadable else { return false }
        lines += 1
        return true
    }
}
