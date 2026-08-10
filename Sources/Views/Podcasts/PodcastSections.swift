// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation

/// Result of the podcast home-section computation (see `PodcastSections`).
nonisolated struct PodcastSectionsResult {
    var nextUp: [LibraryItem] = []
    var recentShows: [RecentShowInfo] = []
    /// Pinchflat Paket B: mirrored shows (origin != nil) render in their OWN
    /// group row instead of "Recently updated" — the group IS their row
    /// (c90390b), so the general grid does not double them. Newest first.
    var mirroredShows: [RecentShowInfo] = []
    var downloaded: [LibraryItem] = []
}

/// Pure one-pass computation of the podcast home sections — extracted from
/// `PodcastsView` so it is testable without UI/global state. All state lookups
/// (play state, last-played timestamp, inbox mode) are injected.
///
/// One `LibraryItem` and one play-state read per episode:
/// - "Continue" (nextUp): in-progress episodes by last listening time, max 10.
/// - "Recently updated": shows by newest episode, with the count of unplayed
///   episodes newer than the last played one (all unplayed without one);
///   shows with inbox mode "off" are excluded.
/// - "Downloaded": episodes present on device, newest first.
enum PodcastSections {

    // MARK: - S2: main-actor snapshot → off-main compute

    /// Everything the off-main computation needs, collected ON the main actor
    /// in one pass (UserDefaults reads, provider dictionaries) — the injected
    /// closures of `compute` may then run on any executor.
    nonisolated struct StateSnapshot: Sendable {
        /// guid (incl. all bridge twins) → stored `[position, tsMs]`.
        let positions: [String: [Double]]
        /// abspod id → server progress.
        let serverProgress: [String: BookProgress]
        /// episode guid → its equivalent ids (incl. self).
        let equivalents: [String: [String]]
        let downloadedIds: Set<String>
        let inboxOff: Set<String>
    }

    @MainActor
    static func snapshot(shows: [PodcastShow]) -> StateSnapshot {
        var positions: [String: [Double]] = [:]
        var equivalents: [String: [String]] = [:]
        var inboxOff: Set<String> = []
        for show in shows {
            if AppStorageKeys.podcastInboxModeValue(show.id) == "off" { inboxOff.insert(show.id) }
            for ep in show.episodes {
                let ids = ABSPodcastProvider.shared.equivalentIds(ep.guid)
                equivalents[ep.guid] = ids
                for id in ids where positions[id] == nil {
                    if let arr = UserDefaults.standard.array(forKey: AppStorageKeys.localPosition(id)) as? [Double],
                       arr.count >= 2 {
                        positions[id] = arr
                    }
                }
            }
        }
        return StateSnapshot(
            positions: positions,
            serverProgress: ABSPodcastProvider.shared.episodeProgress,
            equivalents: equivalents,
            downloadedIds: DownloadManager.shared.downloadedItemIds,
            inboxOff: inboxOff
        )
    }

    /// Nonisolated replication of `podcastPlayState` over the snapshot —
    /// newest-wins across bridge ids, sentinel before the duration guard,
    /// ABS server state when its timestamp is fresher.
    nonisolated static func state(guid: String, duration: Double,
                                  snapshot: StateSnapshot) -> EpisodePlayState {
        let ids = snapshot.equivalents[guid] ?? [guid]
        var bestGuid: String?
        var bestTs = -1.0
        for id in ids {
            if let arr = snapshot.positions[id], arr[1] > bestTs {
                bestTs = arr[1]; bestGuid = id
            }
        }
        if let absId = ids.first(where: { $0.hasPrefix("abspod:") }),
           let bp = snapshot.serverProgress[absId], (bp.lastUpdate) > bestTs {
            if bp.isFinished { return .played }
            if bp.fraction > 0.001 {
                let remaining = duration > 0 ? duration * (1 - bp.fraction) : 0
                return .inProgress(fraction: min(max(bp.fraction, 0), 1), remaining: remaining)
            }
            return .unplayed
        }
        guard let bestGuid, let stored = snapshot.positions[bestGuid] else { return .unplayed }
        let time = stored[0]
        if time >= PodcastProgressStore.playedSentinel { return .played }
        guard duration > 0 else { return .unplayed }
        if time >= duration - 1 { return .played }
        if time > 1 { return .inProgress(fraction: min(max(time / duration, 0), 1), remaining: duration - time) }
        return .unplayed
    }

    /// X1c (pure): the newest episode of each show, newest first — ONE per
    /// show so a daily show doesn't dominate the grid. Generous cap: the grid
    /// itself shows 2 rows collapsed / up to 6 expanded (max 5 columns → 30).
    nonisolated static func newestPerShow(shows: [PodcastShow], limit: Int = 30) -> [String] {
        shows.compactMap { show -> (id: String, ts: Double)? in
            guard let ep = show.episodes.max(by: { $0.pubDate < $1.pubDate }) else { return nil }
            return (ep.guid, ep.pubDate)
        }
        .sorted { $0.ts > $1.ts }
        .prefix(limit)
        .map(\.id)
    }

    nonisolated static func lastPlayed(id: String, snapshot: StateSnapshot) -> Double {
        (snapshot.equivalents[id] ?? [id]).reduce(0.0) { best, eqId in
            let localTs = snapshot.positions[eqId]?.last ?? 0
            let absTs = snapshot.serverProgress[eqId]?.lastUpdate ?? 0
            return max(best, max(localTs, absTs))
        }
    }

    /// Off-main section computation over the snapshot; the main actor only
    /// collects the snapshot and assigns the result.
    nonisolated static func computeDetached(
        shows: [PodcastShow], snapshot: StateSnapshot,
        sort: PodcastSortOption = .zuletztAktualisiert,
        filter: PodcastFilterOption = .alle
    ) async -> PodcastSectionsResult {
        await Task.detached(priority: .userInitiated) {
            compute(
                shows: shows,
                downloadedIds: snapshot.downloadedIds,
                inboxOff: { snapshot.inboxOff.contains($0) },
                playState: { state(guid: $0.id, duration: $0.media?.duration ?? 0, snapshot: snapshot) },
                lastPlayed: { lastPlayed(id: $0, snapshot: snapshot) },
                sort: sort, filter: filter
            )
        }.value
    }

    nonisolated static func compute(
        shows: [PodcastShow],
        downloadedIds: Set<String>,
        inboxOff: (String) -> Bool,
        playState: (LibraryItem) -> EpisodePlayState,
        lastPlayed: (String) -> Double,
        sort: PodcastSortOption = .zuletztAktualisiert,
        filter: PodcastFilterOption = .alle
    ) -> PodcastSectionsResult {
        var picks: [(item: LibraryItem, playedAt: Double)] = []
        var infos: [RecentShowInfo] = []
        var downloadedItems: [LibraryItem] = []

        for show in shows {
            let hideFromInbox = inboxOff(show.id)
            var newest = 0.0
            var lastPlayedAdded: Double?
            var unplayedAdded: [Double] = []
            var showHasDownloads = false

            for ep in show.episodes {
                let item = podcastLibraryItem(show: show, episode: ep)
                newest = max(newest, ep.pubDate)
                switch playState(item) {
                case .inProgress:
                    picks.append((item, lastPlayed(item.id)))
                case .played:
                    lastPlayedAdded = max(lastPlayedAdded ?? 0, item.addedAt ?? 0)
                case .unplayed:
                    unplayedAdded.append(item.addedAt ?? 0)
                }
                if downloadedIds.contains(item.id) {
                    downloadedItems.append(item)
                    showHasDownloads = true
                }
            }

            if !hideFromInbox, newest > 0 {
                let newCount = lastPlayedAdded.map { lp in unplayedAdded.filter { $0 > lp }.count }
                    ?? unplayedAdded.count
                infos.append(RecentShowInfo(
                    show: show, lastUpdated: newest, newCount: newCount,
                    hasDownloads: showHasDownloads, unplayedCount: unplayedAdded.count
                ))
            }
        }

        // Paket B: mirrored shows split into their own group (the group is
        // their row); everything else stays in the general grid.
        let mirrored = infos.filter { $0.show.origin != nil }
        let regular = infos.filter { $0.show.origin == nil }
        return PodcastSectionsResult(
            // Welle 3 / C-Lehre: the SOURCE no longer culls — the row caps
            // its preview (RowPreview), the page shows the full stock. 200 is
            // a sanity bound, not a curation.
            nextUp: picks.sorted { $0.playedAt > $1.playedAt }.prefix(200).map(\.item),
            recentShows: arrange(regular, sort: sort, filter: filter),
            mirroredShows: mirrored.sorted { $0.lastUpdated > $1.lastUpdated },
            downloaded: downloadedItems.sorted { ($0.addedAt ?? 0) > ($1.addedAt ?? 0) }
        )
    }

    /// Pure filter + sort of the show grid (Teil 2, testable). "Recently
    /// updated" = newest episode first (default); "Name A–Z" alphabetical;
    /// "Most unplayed" by unplayed count. Filter drops shows without downloads /
    /// without unplayed episodes.
    nonisolated static func arrange(
        _ infos: [RecentShowInfo], sort: PodcastSortOption, filter: PodcastFilterOption
    ) -> [RecentShowInfo] {
        let filtered = infos.filter { info in
            switch filter {
            case .alle: return true
            case .mitDownloads: return info.hasDownloads
            case .mitUngespielten: return info.unplayedCount > 0
            }
        }
        switch sort {
        case .zuletztAktualisiert:
            return filtered.sorted { $0.lastUpdated > $1.lastUpdated }
        case .nameAZ:
            return filtered.sorted {
                $0.show.title.localizedCaseInsensitiveCompare($1.show.title) == .orderedAscending
            }
        case .meisteUngespielte:
            // Stable tiebreak by recency so equal counts keep a sensible order.
            return filtered.sorted {
                $0.unplayedCount != $1.unplayedCount
                    ? $0.unplayedCount > $1.unplayedCount
                    : $0.lastUpdated > $1.lastUpdated
            }
        }
    }
}
