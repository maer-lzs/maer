// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

// The publisher is a non-Sendable Combine type held nonisolated by a
// MainActor class; the pre-concurrency import is the sanctioned suppression.
@preconcurrency import Combine
import Foundation
import OSLog

/// What moves a held answer (`RoutinePlayback.held`) besides the list: the
/// listening state (also marks adopted from another device and new episodes
/// after a fetch), the downloads and the network. One object for a page to
/// observe, so a rule's line never shows the answer of an earlier moment.
@MainActor
final class RoutineAnswerSources: ObservableObject {
    static let shared = RoutineAnswerSources()
    nonisolated let objectWillChange = ObservableObjectPublisher()
    private var watching: [AnyCancellable] = []

    private init() {
        let changes = objectWillChange
        watching = [
            ListeningRevision.shared.objectWillChange.sink { _ in changes.send() },
            DownloadManager.shared.stock.objectWillChange.sink { _ in changes.send() },
            NetworkMonitor.shared.objectWillChange.sink { _ in changes.send() },
        ]
    }
}

/// A Mär playlist at its start. Every rule of the list (`RoutineRule`)
/// becomes the episodes it picks now, every other entry stays what this
/// device makes of it, in the list's order. The rules end here: the first
/// item and the context only ever get episodes, so no saved state names a
/// rule. A list without rules starts as it always did.
@MainActor
enum RoutinePlayback {
    /// What a start plays, and which of it a rule picked.
    struct Start {
        var items: [LibraryItem]
        /// The ids a rule picked. Such an episode resumes when it comes
        /// first, in order or shuffled; a title of the list starts from the
        /// beginning.
        var fromRule: Set<String>
    }

    /// The entries in order, each rule replaced by what it picks. An item
    /// plays once, the first time the list names it.
    static func expand(_ itemIds: [String], entry: (String) -> LibraryItem?,
                       picks: (RoutineRule) -> [LibraryItem]) -> Start {
        var items: [LibraryItem] = []
        var seen: Set<String> = []
        var fromRule: Set<String> = []
        for id in itemIds {
            let rule = RoutineRule(id: id)
            let found = rule.map(picks) ?? entry(id).map { [$0] } ?? []
            let fresh = found.filter { seen.insert($0.id).inserted }
            if rule != nil { fromRule.formUnion(fresh.map(\.id)) }
            items += fresh
        }
        return Start(items: items, fromRule: fromRule)
    }

    /// What one rule answers now: the episodes it picks, or why it picks none.
    enum Answer {
        case play([LibraryItem])
        case absent(RoutineRule.Absence)
        /// Neither followed nor met this session: this device cannot find
        /// the show behind the rule's feed key.
        case showUnknown

        var items: [LibraryItem] {
            if case .play(let items) = self { return items }
            return []
        }
    }

    /// A rule's line on a list page: the rule, its show as this device
    /// knows it, and what it answers now.
    struct Line {
        var rule: RoutineRule
        var show: PodcastShow?
        var answer: Answer
    }

    /// What the list holds now, each rule with its line.
    struct Held {
        var start: Start
        /// By rule id.
        var lines: [String: Line]
    }

    /// The episodes one rule picks from its show (`answer`).
    static func picks(_ rule: RoutineRule, in show: PodcastShow?, online: Bool,
                      state: (LibraryItem) -> EpisodePlayState,
                      isDownloaded: (String) -> Bool) -> [LibraryItem] {
        answer(rule, in: show, online: online, state: state, isDownloaded: isDownloaded).items
    }

    /// What one rule answers from its show. Heard and begun are `state`'s
    /// answer, begun in the auto-download's sense
    /// (`PodcastAutoDownloadRules.isStarted`); an episode without audio is
    /// none to pick.
    static func answer(_ rule: RoutineRule, in show: PodcastShow?, online: Bool,
                       state: (LibraryItem) -> EpisodePlayState,
                       isDownloaded: (String) -> Bool) -> Answer {
        guard let show else { return .showUnknown }
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
            return .play(ids.compactMap { byId[$0] })
        case .absent(let absence):
            return .absent(absence)
        }
    }

    /// The line a start writes for a rule that picks nothing. Only the
    /// start writes it: the page asks `answer` on every pass, and its lines
    /// would bury the start's.
    static func logAbsence(_ rule: RoutineRule, _ answer: Answer) {
        switch answer {
        case .play: return
        case .absent(let absence):
            Logger.library.notice("ROUTINE rule=\(rule.id, privacy: .public) absent: \(absence.rawValue, privacy: .public)")
        case .showUnknown:
            Logger.library.notice("ROUTINE rule=\(rule.id, privacy: .public) absent: the show is not known on this device")
        }
    }

    /// What one rule answers on this device: the shared judgement and the
    /// downloads this device holds.
    private static func answer(_ rule: RoutineRule, in show: PodcastShow?, online: Bool) -> Answer {
        answer(rule, in: show, online: online, state: { podcastPlayState(for: $0) },
               isDownloaded: { DownloadManager.shared.isDownloaded(itemId: $0) })
    }

    /// The show of a feed key among the shows this device knows: the
    /// followed ones, then the ones met while browsing this session.
    static func show(feedKey: String) -> PodcastShow? {
        followed(feedKey: feedKey)
            ?? BrowsedEpisodes.shared.sessionShows().first { PodcastIdentity.feedKey($0.feedURL) == feedKey }
    }

    /// The followed show of a feed key.
    static func followed(feedKey: String) -> PodcastShow? {
        PodcastSubscriptions.shared.shows.first { PodcastIdentity.feedKey($0.feedURL) == feedKey }
    }

    /// What the list plays from what this device holds now, without asking
    /// a feed: the page's lines, shuffle and covers. The page asks
    /// synchronously, so it reads the monitor, not the door. The answer
    /// moves with the list, the listening state (`ListeningRevision`, also
    /// for marks adopted from another device and for new episodes), the
    /// downloads (`DownloadStock`) and the network (`NetworkMonitor`); a
    /// page that shows it observes all four.
    static func held(_ list: MaerPlaylists.Playlist, in store: MaerPlaylists) -> Held {
        let online = NetworkMonitor.shared.isConnected
        var lines: [String: Line] = [:]
        for id in list.itemIds where lines[id] == nil {
            guard let rule = RoutineRule(id: id) else { continue }
            let known = show(feedKey: rule.feedKey)
            lines[id] = Line(rule: rule, show: known, answer: answer(rule, in: known, online: online))
        }
        let start = expand(list.itemIds, entry: { store.resolution(of: $0, in: list).item }) { rule in
            lines[rule.id]?.answer.items ?? []
        }
        return Held(start: start, lines: lines)
    }

    /// The snapshot a rule entry travels with: its show's title and, when
    /// the address carries no access, its picture. The rule in words is not
    /// part of it; every device says it in its own language from the id.
    static func carried(forRule itemId: String) -> CarriedItem? {
        guard let rule = RoutineRule(id: itemId), let show = show(feedKey: rule.feedKey) else { return nil }
        return snapshot(itemId, show: show, premium: PodcastSubscriptions.premiumAnswer(show.feedURL))
    }

    /// The snapshot from a show, pure. A premium feed's picture or a
    /// picture address that carries access stays home. `premium` is nil
    /// while the feed's paid state cannot be read now; the picture stays
    /// home then too, since one that travelled stays on the other devices.
    nonisolated static func snapshot(_ itemId: String, show: PodcastShow, premium: Bool?) -> CarriedItem? {
        guard let title = SyncCarried.usableTitle(show.title, for: itemId) else { return nil }
        let picture = show.artworkURL.flatMap { (premium ?? true) || PodcastFeedAddress.carriesAccess($0) ? nil : $0 }
        return CarriedItem(id: itemId, title: title, coverURL: picture)
    }

    /// The followed show to offer the auto-download for after these entries
    /// went into a list: the first rule's show, when its downloads are not
    /// on yet. Offline a routine plays only what is downloaded; the offer
    /// asks, nothing switches it on unasked.
    static func autoDownloadOffer(for itemIds: [String],
                                  followedShow: (String) -> PodcastShow? = { followed(feedKey: $0) },
                                  isEnabled: (String) -> Bool = { PodcastAutoDownload.isEnabled($0) }) -> PodcastShow? {
        for rule in itemIds.compactMap(RoutineRule.init(id:)) {
            if let show = followedShow(rule.feedKey) { return isEnabled(show.id) ? nil : show }
        }
        return nil
    }

    /// A rule's cover: its show's picture as this device knows it.
    static func coverURL(forRule itemId: String) -> URL? {
        guard let rule = RoutineRule(id: itemId) else { return nil }
        return show(feedKey: rule.feedKey)?.artworkURL.flatMap(URL.init(string:))
    }

    /// The start of a list. With rules and a connection, the feeds of their
    /// shows are asked first, together under the surface budget, so the
    /// newest episode is today's; a feed that does not answer in time
    /// leaves the episodes this device holds. Then the first item opens and
    /// the rest becomes the context. Answers whether anything was handed to
    /// playback: a button is disabled when nothing would play, a shortcut
    /// has no button and says so instead.
    @discardableResult
    static func start(_ list: MaerPlaylists.Playlist, in store: MaerPlaylists,
                      on coordinator: PlayerCoordinator) async -> Bool {
        let online = await Reachability.isConnected()
        let fresh = online ? await refreshed(list.itemIds.compactMap(RoutineRule.init(id:))) : [:]
        await DownloadManager.shared.ensureScanned()
        let start = expand(list.itemIds, entry: { store.resolution(of: $0, in: list).item }) { rule in
            let said = answer(rule, in: fresh[rule.feedKey] ?? show(feedKey: rule.feedKey), online: online)
            logAbsence(rule, said)
            return said.items
        }
        await coordinator.playInOrder(items: start.items, contextSource: list.name,
                                      resuming: start.fromRule)
        return !start.items.isEmpty
    }

    /// What a shortcut's request for a list comes to.
    enum Request: Equatable {
        case start(MaerPlaylists.Playlist)
        /// The store's start read missed rows: the list may still come, so
        /// the request waits and says nothing.
        case wait
        /// The rows are read and the list is not among them.
        case missing
    }

    /// The request for one list id against the lists this device holds.
    nonisolated static func request(_ id: String, in lists: [MaerPlaylists.Playlist],
                                    complete: Bool) -> Request {
        if let list = lists.first(where: { $0.id == id }) { return .start(list) }
        return complete ? .missing : .wait
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
            if let followed = subscriptions.shows.first(where: { PodcastIdentity.feedKey($0.feedURL) == key }),
               await subscriptions.absorb(answer, showId: followed.id) != nil {
                out[key] = show(feedKey: key)
            } else {
                out[key] = answer
            }
        }
        return out
    }
}
