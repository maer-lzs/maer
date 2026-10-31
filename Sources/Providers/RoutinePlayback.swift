// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation
import OSLog

/// A Mär playlist at its start. Every rule of the list (`RoutineRule`)
/// becomes the episodes it picks now, every other entry stays what this
/// device makes of it, in the list's order. The rules end here: the first
/// item and the context only ever get episodes, so no saved state names a
/// rule. A list without rules starts as it always did.
@MainActor
enum RoutinePlayback {
    /// What a start plays, and whether its first item came from a rule.
    struct Start {
        var items: [LibraryItem]
        /// A begun episode a rule picked resumes; a list's first title
        /// otherwise starts from the beginning.
        var firstFromRule: Bool
    }

    /// The entries in order, each rule replaced by what it picks. An item
    /// plays once, the first time the list names it.
    static func expand(_ itemIds: [String], entry: (String) -> LibraryItem?,
                       picks: (RoutineRule) -> [LibraryItem]) -> Start {
        var items: [LibraryItem] = []
        var firstFromRule = false
        for id in itemIds {
            let fromRule = RoutineRule(id: id)
            let found = fromRule.map(picks) ?? entry(id).map { [$0] } ?? []
            let fresh = found.filter { item in !items.contains { $0.id == item.id } }
            if items.isEmpty, !fresh.isEmpty { firstFromRule = fromRule != nil }
            items += fresh
        }
        return Start(items: items, firstFromRule: firstFromRule)
    }

    /// What one rule picks from its show. Heard and begun are `state`'s
    /// answer, begun in the auto-download's sense
    /// (`PodcastAutoDownloadRules.isStarted`); an episode without audio is
    /// none to pick.
    static func picks(_ rule: RoutineRule, in show: PodcastShow?, online: Bool,
                      state: (LibraryItem) -> EpisodePlayState,
                      isDownloaded: (String) -> Bool) -> [LibraryItem] {
        guard let show else {
            Logger.library.notice("ROUTINE rule=\(rule.id, privacy: .public) absent: the show is not known on this device")
            return []
        }
        let pairs = show.episodes.filter(\.isPlayable).map { ($0, podcastLibraryItem(show: show, episode: $0)) }
        let byId = Dictionary(pairs.map { ($0.1.id, $0.1) }) { first, _ in first }
        let episodes = pairs.map { episode, item in
            let mark = state(item)
            return RoutineRule.Episode(guid: item.id, pubDate: episode.pubDate, isPlayed: mark == .played,
                                       isStarted: PodcastAutoDownloadRules.isStarted(mark, duration: episode.duration),
                                       isDownloaded: isDownloaded(item.id))
        }
        switch rule.resolve(episodes, online: online) {
        case .play(let ids):
            return ids.compactMap { byId[$0] }
        case .absent(let absence):
            Logger.library.notice("ROUTINE rule=\(rule.id, privacy: .public) absent: \(absence.rawValue, privacy: .public)")
            return []
        }
    }

    /// What one rule picks on this device: the shared judgement and the
    /// downloads this device holds.
    private static func picks(_ rule: RoutineRule, in show: PodcastShow?, online: Bool) -> [LibraryItem] {
        picks(rule, in: show, online: online, state: { podcastPlayState(for: $0) },
              isDownloaded: { DownloadManager.shared.isDownloaded(itemId: $0) })
    }

    /// The show of a feed key among the shows this device knows: the
    /// followed ones, then the ones met while browsing this session.
    static func show(feedKey: String) -> PodcastShow? {
        let named: (PodcastShow) -> Bool = { PodcastSubscriptions.feedKey($0.feedURL) == feedKey }
        return PodcastSubscriptions.shared.shows.first(where: named) ?? BrowsedEpisodes.shared.sessionShows().first(where: named)
    }

    /// What the list plays from what this device holds now, without asking
    /// a feed: the page's count, shuffle and covers. The page asks
    /// synchronously, so it reads the monitor, not the door.
    static func held(_ list: MaerPlaylists.Playlist, in store: MaerPlaylists) -> Start {
        let online = NetworkMonitor.shared.isConnected
        return expand(list.itemIds, entry: { store.resolution(of: $0, in: list).item }) { rule in
            picks(rule, in: show(feedKey: rule.feedKey), online: online)
        }
    }

    /// The start of a list. With rules and a connection, the feeds of their
    /// shows are asked first, together under the surface budget, so the
    /// newest episode is today's; a feed that does not answer in time
    /// leaves the episodes this device holds. Then the first item opens and
    /// the rest becomes the context.
    static func start(_ list: MaerPlaylists.Playlist, in store: MaerPlaylists,
                      on coordinator: PlayerCoordinator) async {
        let online = await Reachability.isConnected()
        let fresh = online ? await refreshed(list.itemIds.compactMap(RoutineRule.init(id:))) : [:]
        await DownloadManager.shared.ensureScanned()
        let start = expand(list.itemIds, entry: { store.resolution(of: $0, in: list).item }) { rule in
            picks(rule, in: fresh[rule.feedKey] ?? show(feedKey: rule.feedKey), online: online)
        }
        await coordinator.playInOrder(items: start.items, contextSource: list.name,
                                      restartFirst: !start.firstFromRule)
    }

    /// The rules' shows as their feeds answer now, by feed key. A followed
    /// show takes the answer into its stock and is read from there.
    private static func refreshed(_ rules: [RoutineRule]) async -> [String: PodcastShow] {
        var asked: [String: URL] = [:]
        for rule in rules where asked[rule.feedKey] == nil {
            if let known = show(feedKey: rule.feedKey), let url = PodcastFeedAddress.requestURL(known.feedURL) {
                asked[rule.feedKey] = url
            }
        }
        guard !asked.isEmpty else { return [:] }
        let feeds = asked
        let answers = await SourceBudget.value(default: [String: PodcastShow]()) {
            await withTaskGroup(of: (String, PodcastShow?).self) { group in
                for (key, url) in feeds {
                    group.addTask { (key, await PodcastSubscriptions.fetchAndParse(feedURL: url)) }
                }
                var shows: [String: PodcastShow] = [:]
                for await (key, show) in group { if let show { shows[key] = show } }
                return shows
            }
        }
        var out: [String: PodcastShow] = [:]
        let subscriptions = PodcastSubscriptions.shared
        for (key, answer) in answers {
            if let followed = subscriptions.shows.first(where: { PodcastSubscriptions.feedKey($0.feedURL) == key }),
               await subscriptions.absorb(answer, showId: followed.id) != nil {
                out[key] = show(feedKey: key)
            } else {
                out[key] = answer
            }
        }
        return out
    }
}
