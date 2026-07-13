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
        pick(
            shows: allShows(),
            finishedItemId: finishedItemId,
            equivalentIds: { ABSPodcastProvider.shared.equivalentIds($0) },
            playState: { podcastPlayState(for: $0) },
            lastPlayed: { id in
                // Bridge-aware: the freshest progress of an episode can live
                // under its rss:/abspod: twin — take the max over all ids.
                ABSPodcastProvider.shared.equivalentIds(id).reduce(0.0) { best, eqId in
                    let localTs = (UserDefaults.standard.array(forKey: AppStorageKeys.localPosition(eqId)) as? [Double])?.last ?? 0
                    let absTs = ABSPodcastProvider.shared.episodeProgress[eqId]?.lastUpdate ?? 0
                    return max(best, max(localTs, absTs))
                }
            }
        )
    }

    /// Pure decision core (testable): all state lookups injected.
    /// The finished episode is matched bridge-aware — a finished `rss:` playback
    /// must find its show even when the catalog lists the ABS variant
    /// (`abspod:` guids), otherwise step 1 (same show) would be skipped.
    static func pick(
        shows: [PodcastShow],
        finishedItemId: String,
        equivalentIds: (String) -> [String],
        playState: (LibraryItem) -> EpisodePlayState,
        lastPlayed: (String) -> Double
    ) -> LibraryItem? {
        let finishedIds = Set(equivalentIds(finishedItemId))
        func isFinishedEpisode(_ guid: String) -> Bool {
            finishedIds.contains(guid) || !finishedIds.isDisjoint(with: equivalentIds(guid))
        }

        var finishedShow: PodcastShow?
        var finishedEpisode: PodcastEpisode?
        for show in shows {
            if let ep = show.episodes.first(where: { isFinishedEpisode($0.guid) }) {
                finishedShow = show
                finishedEpisode = ep
                break
            }
        }

        // 1. Same show: the NEXT NEWER unheard episode — strictly forward in
        //    time; episodes sharing the finished pubDate (batch releases) count
        //    too, ordered stably by guid.
        if let show = finishedShow, let finished = finishedEpisode {
            let candidate = show.episodes
                .filter {
                    !isFinishedEpisode($0.guid)
                        && ($0.pubDate > finished.pubDate
                            || ($0.pubDate == finished.pubDate && $0.guid > finished.guid))
                }
                .sorted {
                    $0.pubDate != $1.pubDate ? $0.pubDate < $1.pubDate : $0.guid < $1.guid
                }
                .lazy
                .map { podcastLibraryItem(show: show, episode: $0) }
                .first { item in
                    if case .played = playState(item) { return false }
                    return true
                }
            if let candidate { return candidate }
        }

        // 2. Otherwise continue what was played most recently: the last started,
        //    still-in-progress episode across all subscriptions.
        var started: [(item: LibraryItem, ts: Double)] = []
        for show in shows {
            for ep in show.episodes {
                guard !isFinishedEpisode(ep.guid) else { continue }
                let item = podcastLibraryItem(show: show, episode: ep)
                if case .inProgress = playState(item) {
                    started.append((item, lastPlayed(item.id)))
                }
            }
        }
        return started.max(by: { $0.ts < $1.ts })?.item
    }
}
