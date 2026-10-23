// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import SwiftUI

/// What the APP has to do at launch and on every scene change, under a name
/// that says so.
///
/// All of this lived in `LibraryView`: fourteen singleton grips in a view
/// whose actual job is hosting the tabs. It was there for one reason only,
/// that the library happens to be the first screen, and the consequence was
/// that the app's start-up ORDER was a detail of a 1584-line view body and
/// could not be stated, tested or fenced anywhere.
///
/// The order is the point, not the tidiness. It follows the same rule the
/// catalog runs follow: **housekeeping comes after the
/// content the person is waiting for.** The library, the mini-player and a
/// pending resume request go first; queues, services and maintenance follow.
@MainActor
enum AppHousekeeping {

    /// Progress and bookmarks that could not be sent last time (the app was
    /// closed offline). Must run BEFORE the sync-status line is refreshed,
    /// which is why it is its own step instead of being folded into the rest.
    static func flushQueues(provider: any AudioProvider) async {
        // Per entry the provider that owns the id. For an id nobody owns
        // the router answers with a provider that REFUSES, and that one
        // stays out here: an entry without an owner is kept, never offered
        // to anyone.
        await SyncQueue.shared.flush(targetFor: AppSession.shared.progressTarget)
        await BookmarkQueue.shared.flush(provider: provider)
    }

    /// Does the server have podcast libraries, and the iCloud services.
    static func startServices() async {
        // The podcast tab appears even without local RSS subscriptions
        // (1 request, no full load).
        await AppSession.shared.absPodcastProvider.refreshAvailability()
        // The quota watch stands BEFORE the services and does not depend on
        // any of them. It is the one place that asks why the key-value store
        // changed, and the case worth catching (the channel fills because
        // podcastProgress fills it) must not hang on a service that may be
        // switched off.
        CloudQuotaWatch.shared.start()
        // Reconcile podcast progress via iCloud (across devices).
        pot.start()
        ListeningStatsStore.shared.start()
        // Same switch, same store, same moment. The playlists travel with the
        // podcast progress or not at all.
        MaerPlaylistCloudSync.shared.start()
        // The travelling user choices (sorts, browse choices, favorites,
        // per-show settings, …). One mechanism, same switch.
        UserChoiceCloudSync.shared.start()
        // Takeover channel: who is playing what (self-pause + hint line).
        PlaybackClaimSync.shared.start()
        // The feed credentials over the service, sealed. The seventh runner
        // starts where the six start; until this line nobody started it,
        // and the page showed a code that carried nothing.
        FeedAuthSync.shared.startIfConfigured(by: "housekeeping")
        // The listen log and the listening history follow the account like
        // the families: enrolled before any sign-in can come, so they hear
        // the change at its moment.
        PodcastListenLog.shared.followAtStart()
        ListenHistory.shared.followAtStart()
        // MetricKit feeds only the diagnostics page, so it runs only in
        // builds from Xcode, never in a release build. The gate may ask the
        // App Store for the environment, so in its own task: nothing here
        // waits on the network.
        #if DEBUG
        Task { await MetricReceiver.startIfAllowed() }
        #endif
        // The catalogue stock runs start with the app, not with a page:
        // every collection whose source is on, continuing what an earlier
        // run (or an earlier version) reached, so a page is whole the first
        // time it opens. In their own task: nothing here waits.
        if !Self.catalogRunsMustStaySilent {
            Task { await CatalogStockService.shared.startRuns() }
        }
    }

    /// The podcast pot's iCloud carrier, as the start and both scene
    /// changes reach it: one grip for the file instead of three.
    private static var pot: PodcastCloudSync { PodcastCloudSync.shared }

    /// The test host and the UI harness never reach the catalogues from the
    /// start: a suite that mounts the library would otherwise download a
    /// collection in the middle of a run. The same rule the shared carriers
    /// follow.
    static var catalogRunsMustStaySilent: Bool {
        #if DEBUG
        TestProcess.isUnderTest
        #else
        false
        #endif
    }

    /// Cover cache and the Navidrome id move.
    ///
    /// LAST on purpose. Each hands its work to a background task
    /// straight away, but each ARGUMENT is still built on the main actor, and
    /// they used to stand ahead of `showCachedLibraryIfAvailable`: the person
    /// waited on the cover list of every download before seeing their library.
    /// Nothing here is worth a single frame of that.
    static func maintenance() {
        // Cover maintenance (TTL, size limit, orphaned persistent covers),
        // after the downloads' scan, inside the sweep's own task.
        Artwork.sweep()
        // Once per server address: this device's stores take Navidrome's
        // new ids, after the server reported 0.64 or later.
        Task { await NavidromeRekeyRun.runIfDue(by: "maintenance") }
    }

    /// The book server's access could not be read at start (before the first
    /// unlock after a restart): every return reads it again, and once it
    /// reads as signed in the library loads, without a force-quit. The
    /// return is the occasion: a process started before the first unlock
    /// reaches the person only through it.
    static func rereadUnknownAccess(auth: AuthViewModel, load: @escaping @MainActor () async -> Void) {
        guard auth.rereadIfUnknown() else { return }
        Task { await load() }
    }

    /// The app-level half of a scene change. The VIEW keeps its own half (its
    /// library reload, progress refresh, quick actions), because those need
    /// view state and this does not.
    static func sceneChanged(to phase: ScenePhase) {
        // Drive mode idle-timer discipline: background always releases it.
        // Asked for EVERY phase, `.inactive` included, so it stays outside
        // the two branches below.
        DriveModeController.shared.scenePhaseChanged(active: phase == .active)
        switch phase {
        case .active:
            // First: a sync access unreadable at start is read again, so the
            // pull below already goes over the service.
            AccessFollowers.followOnceTheAccessReads(by: "scene active")
            // Pull only: coming back is not an occasion to write the pot.
            let stands = pot
            stands.reconcile(pushing: false, caller: "scene active")
            Task { await stands.pull(by: "scene active") }
            // The other CloudKit families (statistics, playlists, choices)
            // fetch here too. The pot's CloudKit carrier is asked twice and
            // fetches once: its refresh coalesces while one is running.
            // An older service is asked once more on the way back, before
            // the refresh that would otherwise find the rounds stopped.
            MaerSyncCarriers.session.askAgainOnReturn()
            Task { await CarrierRefreshers.refreshAll(by: "scene active") }
            // Recheck the active sources and reconnect silently. An outage
            // must never require a force-quit to recover.
            let session = AppSession.shared
            session.musicProvider.reconnectIfNeeded()
            rereadUnknownAccess(auth: session.authViewModel) { await session.libraryViewModel.loadLibrary() }
            // The cover cap on returning is NOT here: it hangs on the calm
            // gate, and „when is the scrolling calm" is the view's question.
            // A type that is no view and schedules UI work is exactly the
            // layering violation `ScrollCalmFenceTests` counts down, and
            // moving it in here would raise that stock.
        case .background:
            pot.reconcile(caller: "scene background")
            // Re-run the cover-cache cap on backgrounding, not only at
            // launch. Otherwise a long session's cover growth stays uncapped
            // until the next cold start.
            Artwork.sweep()
            // One line per foreign service for the session so far, so a
            // device run brings the numbers of the courtesy rule.
            Task { await HostCourtesy.shared.report() }
        default:
            break
        }
    }
}
