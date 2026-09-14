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
/// The order is the point, not the tidiness. It follows the same rule the E55
/// order writes down for the catalog runs: **housekeeping comes after the
/// content the person is waiting for.** The library, the mini-player and a
/// pending resume request go first; queues, services and maintenance follow.
@MainActor
enum AppHousekeeping {
    /// Progress and bookmarks that could not be sent last time (the app was
    /// closed offline). Must run BEFORE the sync-status line is refreshed,
    /// which is why it is its own step instead of being folded into the rest.
    static func flushQueues(provider: any AudioProvider) async {
        await SyncQueue.shared.flush(apiClient: provider)
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
        PodcastCloudSync.shared.start()
        ListeningStatsStore.shared.start()
        // Same switch, same store, same moment. The playlists travel with the
        // podcast progress or not at all.
        MaerPlaylistCloudSync.shared.start()
        // The travelling user choices (sorts, browse choices, favorites,
        // per-show settings, …). One mechanism, same switch.
        UserChoiceCloudSync.shared.start()
        // Takeover channel: who is playing what (self-pause + hint line).
        PlaybackClaimSync.shared.start()
    }

    /// Cover cache, download repair, one-time deep validation.
    ///
    /// LAST on purpose. Each of the three hands its work to a background task
    /// straight away, but each ARGUMENT is still built on the main actor, and
    /// they used to stand ahead of `showCachedLibraryIfAvailable`: the person
    /// waited on the cover list of every download before seeing their library.
    /// Nothing here is worth a single frame of that.
    static func maintenance() {
        // Cover maintenance (TTL, size limit, orphaned persistent covers).
        Artwork.sweep(active: DownloadManager.shared.downloadedCoverURLs)
        // Download maintenance: repair wrong file extensions of all books.
        DownloadManager.shared.performMaintenance()
        // One-time: remove unreadable old files (auto-heal replaces them).
        DownloadManager.shared.performDeepValidation()
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
            // Pull only: coming back is not an occasion to write the pot.
            PodcastCloudSync.shared.reconcile(pushing: false, caller: "scene active")
            Task { await PodcastCloudSync.shared.pull(by: "scene active") }
            // The other CloudKit families (statistics, playlists, choices)
            // fetch here too. The pot's CloudKit carrier is asked twice and
            // fetches once: its refresh coalesces while one is running.
            Task { await CloudKitRefreshers.refreshAll(by: "scene active") }
            // Recheck the active sources and reconnect silently. An outage
            // must never require a force-quit to recover.
            AppSession.shared.musicProvider.reconnectIfNeeded()
            // The cover cap on returning is NOT here: it hangs on the calm
            // gate, and „when is the scrolling calm" is the view's question.
            // A type that is no view and schedules UI work is exactly the
            // layering violation `ScrollCalmFenceTests` counts down (Weg B),
            // and moving it in here would have raised that stock. It caught
            // this, one run before the commit.
        case .background:
            PodcastCloudSync.shared.reconcile(caller: "scene background")
            // Re-run the cover-cache cap on backgrounding, not only at
            // launch. Otherwise a long session's cover growth stays uncapped
            // until the next cold start.
            Artwork.sweep(active: DownloadManager.shared.downloadedCoverURLs)
        default:
            break
        }
    }
}
