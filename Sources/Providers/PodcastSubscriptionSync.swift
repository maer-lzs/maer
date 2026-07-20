// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Reconciles local RSS subscriptions with the Audiobookshelf server. ABS is
/// the canonical, cross-device syncing source: every locally subscribed feed
/// not yet on the server is created there; an archived server entry is
/// reactivated instead of recreated. Nothing is deleted (unsubscribe = archive,
/// server history stays). Via the feed-URL dedup in `allShows` the app then
/// shows each feed only once (ABS preferred) — RSS stays as an offline/fallback
/// source in the background.
@MainActor
enum PodcastSubscriptionSync {
    struct Report: Equatable {
        var pushed = 0          // newly created on the server
        var reactivated = 0     // reactivated an archived server entry
        var alreadySynced = 0   // already on the server
        var failed: [String] = []

        var isEmpty: Bool {
            pushed == 0 && reactivated == 0 && alreadySynced == 0 && failed.isEmpty
        }
    }

    /// Is the auto-reconcile running/did it run this session? Prevents every tab
    /// switch from querying the server again.
    private static var didAutoReconcile = false
    private static var isRunning = false

    /// Mirror local RSS subscriptions to the server. Idempotent — repeated calls
    /// create nothing twice. Never runs two passes at once.
    /// - Parameter refreshExistingCovers: also re-push the high-resolution feed
    ///   cover for already-synced shows (manual only — the auto-reconcile leaves
    ///   existing covers alone).
    @discardableResult
    static func reconcile(refreshExistingCovers: Bool = false) async -> Report {
        var report = Report()
        guard !isRunning else { return report }
        isRunning = true
        defer { isRunning = false }

        let abs = ABSPodcastProvider.shared
        // Without a server podcast library there is no target to mirror to.
        guard abs.hasPodcasts else { return report }
        // Load the real server state first, otherwise we might create duplicates.
        await abs.refresh()

        // Index server feeds (active + archived) normalized.
        var serverByURL: [String: PodcastShow] = [:]
        for show in abs.shows where !show.feedURL.isEmpty {
            serverByURL[PodcastSubscriptions.normalizeFeedURL(show.feedURL)] = show
        }

        // Dedupe local subscriptions internally (same normalized URL only once).
        var seen = Set<String>()
        for show in PodcastSubscriptions.shared.shows where !show.feedURL.isEmpty {
            let norm = PodcastSubscriptions.normalizeFeedURL(show.feedURL)
            guard seen.insert(norm).inserted else { continue }

            if let existing = serverByURL[norm] {
                if abs.archivedShowIds.contains(existing.id) {
                    abs.setArchived(existing.id, false)
                    report.reactivated += 1
                } else {
                    report.alreadySynced += 1
                }
                if refreshExistingCovers, let cover = show.artworkURL, !cover.isEmpty {
                    await abs.updateShowCover(showId: existing.id, coverURL: cover)
                }
                continue
            }
            // Push our high-resolution feed cover (itunes:image) to the server
            // too — ABS otherwise often pulls the smaller RSS <image> on create.
            if let error = await abs.subscribeOnServer(feedURL: show.feedURL,
                                                       coverURL: show.artworkURL) {
                report.failed.append("\(show.title): \(error)")
            } else {
                report.pushed += 1
            }
        }

        // Lift local listening history onto the matching server episodes (only
        // where local is newer; applies to episodes that exist on the server).
        await abs.pushLocalHistoryToServer()
        return report
    }

    /// Reconcile automatically once per app session, as soon as an ABS podcast
    /// server is reachable and there are local subscriptions to mirror at all.
    static func autoReconcileIfNeeded() async {
        guard !didAutoReconcile,
              ABSPodcastProvider.shared.hasPodcasts,
              !PodcastSubscriptions.shared.shows.isEmpty else { return }
        didAutoReconcile = true
        await reconcile()
    }
}
