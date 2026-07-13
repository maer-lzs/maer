import Foundation

/// Picks the next podcast episode to auto-play after one finishes when the
/// Up-Next queue is empty. Order (user choice): the next NEWER unheard episode of
/// the SAME show (move forward in time, never to an older one); if the show has
/// no newer unheard episode, continue with what was played most recently (the
/// last started, still-in-progress episode across all subscriptions).
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
        var finishedPub: Double?
        if let show = finishedShow {
            finishedPub = show.episodes
                .first { podcastLibraryItem(show: show, episode: $0).id == finishedItemId }?
                .pubDate
        }

        // 1. Same show: the NEXT NEWER unheard episode (closest pubDate above the
        //    finished one) — move forward in time, never back to an older one.
        if let show = finishedShow, let pub = finishedPub,
           let item = nextNewerUnheard(in: show, after: pub) {
            return item
        }

        // 2. Otherwise continue what was played most recently: the last started,
        //    still-in-progress episode across all subscriptions.
        var started: [(item: LibraryItem, ts: Double)] = []
        for show in shows {
            for ep in show.episodes {
                let item = podcastLibraryItem(show: show, episode: ep)
                guard item.id != finishedItemId else { continue }
                if case .inProgress = podcastPlayState(for: item) {
                    started.append((item, lastPlayed(item.id)))
                }
            }
        }
        return started.max(by: { $0.ts < $1.ts })?.item
    }

    /// The unheard episode with the smallest pubDate strictly newer than `pub`.
    private static func nextNewerUnheard(in show: PodcastShow, after pub: Double) -> LibraryItem? {
        show.episodes
            .filter { $0.pubDate > pub }
            .sorted { $0.pubDate < $1.pubDate }   // closest newer first
            .lazy
            .map { podcastLibraryItem(show: show, episode: $0) }
            .first { item in
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
