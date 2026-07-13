import Foundation

/// Result of the podcast home-section computation (see `PodcastSections`).
struct PodcastSectionsResult {
    var nextUp: [LibraryItem] = []
    var recentShows: [RecentShowInfo] = []
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
    static func compute(
        shows: [PodcastShow],
        downloadedIds: Set<String>,
        inboxOff: (String) -> Bool,
        playState: (LibraryItem) -> EpisodePlayState,
        lastPlayed: (String) -> Double
    ) -> PodcastSectionsResult {
        var picks: [(item: LibraryItem, playedAt: Double)] = []
        var infos: [RecentShowInfo] = []
        var downloadedItems: [LibraryItem] = []

        for show in shows {
            let hideFromInbox = inboxOff(show.id)
            var newest = 0.0
            var lastPlayedAdded: Double?
            var unplayedAdded: [Double] = []

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
                if downloadedIds.contains(item.id) { downloadedItems.append(item) }
            }

            if !hideFromInbox, newest > 0 {
                let newCount = lastPlayedAdded.map { lp in unplayedAdded.filter { $0 > lp }.count }
                    ?? unplayedAdded.count
                infos.append(RecentShowInfo(show: show, lastUpdated: newest, newCount: newCount))
            }
        }

        return PodcastSectionsResult(
            nextUp: picks.sorted { $0.playedAt > $1.playedAt }.prefix(10).map(\.item),
            recentShows: infos.sorted { $0.lastUpdated > $1.lastUpdated },
            downloaded: downloadedItems.sorted { ($0.addedAt ?? 0) > ($1.addedAt ?? 0) }
        )
    }
}
