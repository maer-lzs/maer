import Foundation

/// Picks the next podcast episode to auto-play after one finishes when the
/// Up-Next queue is empty. Binge order (user choice): the next unheard episode
/// of the SAME show first; only when that show is exhausted, fall back to other
/// subscriptions — the most recently started (in-progress) episode, else the
/// newest unheard one.
@MainActor
enum PodcastAutoContinue {
    /// Shows of all podcast sources (RSS + ABS), deduplicated by feed URL
    /// (ABS preferred on a duplicate). Mirrors `PodcastsView.allShows`.
    static func allShows() -> [PodcastShow] {
        let abs = ABSPodcastProvider.shared.activeShows
        let absFeeds = Set(abs.map { PodcastSubscriptions.normalizeFeedURL($0.feedURL) })
        let rssOnly = PodcastSubscriptions.shared.shows.filter {
            !absFeeds.contains(PodcastSubscriptions.normalizeFeedURL($0.feedURL))
        }
        return abs + rssOnly
    }

    /// Resolves a show from a feed URL (for value-based navigation routes).
    static func show(forFeedURL feedURL: String) -> PodcastShow? {
        let target = PodcastSubscriptions.normalizeFeedURL(feedURL)
        return allShows().first { PodcastSubscriptions.normalizeFeedURL($0.feedURL) == target }
    }

    static func next(after finishedItemId: String) -> LibraryItem? {
        let shows = allShows()
        let finishedShow = shows.first { show in
            show.episodes.contains { podcastLibraryItem(show: show, episode: $0).id == finishedItemId }
        }

        // 1. Same show: newest unheard episode (excluding the finished one).
        if let show = finishedShow, let item = newestUnheard(in: show, excluding: finishedItemId) {
            return item
        }

        // 2./3. Other shows: most recently started, else newest unheard.
        var started: [(item: LibraryItem, ts: Double)] = []
        var unheard: [(item: LibraryItem, pub: Double)] = []
        for show in shows where show.id != finishedShow?.id {
            for ep in show.episodes {
                let item = podcastLibraryItem(show: show, episode: ep)
                switch podcastPlayState(for: item) {
                case .inProgress: started.append((item, lastPlayed(item.id)))
                case .unplayed: unheard.append((item, ep.pubDate))
                case .played: break
                }
            }
        }
        if let best = started.max(by: { $0.ts < $1.ts }) { return best.item }
        if let best = unheard.max(by: { $0.pub < $1.pub }) { return best.item }
        return nil
    }

    /// The newest not-yet-finished episode of a show, excluding one id.
    private static func newestUnheard(in show: PodcastShow, excluding id: String) -> LibraryItem? {
        show.episodes
            .sorted { $0.pubDate > $1.pubDate }
            .lazy
            .map { podcastLibraryItem(show: show, episode: $0) }
            .first { item in
                guard item.id != id else { return false }
                if case .played = podcastPlayState(for: item) { return false }
                return true
            }
    }

    private static func lastPlayed(_ itemId: String) -> Double {
        let localTs = (UserDefaults.standard.array(forKey: AppStorageKeys.localPosition(itemId)) as? [Double])?.last ?? 0
        let absTs = ABSPodcastProvider.shared.episodeProgress[itemId]?.lastUpdate ?? 0
        return max(localTs, absTs)
    }
}
