// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation

/// An entry of a routine that names no episode but a rule over one show,
/// resolved when the routine starts: the newest episode, or the next one to
/// three from where the listener stands.
///
/// It lives as an id in a Mär playlist's `itemIds` (`rule:newest:<feedKey>`,
/// `rule:next:<feedKey>`, `rule:next:<n>:<feedKey>`): every carrier takes it
/// along as text, no field a build without routines would drop on its next
/// write, and such a build shows it dimmed and skips it. The show is named
/// by its feed key, never by its address: ids stand in the log, and a paid
/// feed carries its access in the address.
nonisolated struct RoutineRule: Hashable, Sendable {
    enum Kind: Hashable, Sendable {
        case newest
        /// The next `count` episodes in order.
        case next(count: Int)
    }

    let kind: Kind
    let feedKey: String

    /// How many episodes "next" may take.
    static let counts = 1...3

    init?(kind: Kind, feedKey: String) {
        guard !feedKey.isEmpty, !feedKey.contains(":") else { return nil }
        if case .next(let count) = kind, !Self.counts.contains(count) { return nil }
        self.kind = kind
        self.feedKey = feedKey
    }

    /// The rule an id names, or nil for any other id or a form this build
    /// does not read (a count outside 1 to 3 among them).
    init?(id: String) {
        guard id.hasPrefix(ItemNamespace.routinePrefix) else { return nil }
        let parts = id.dropFirst(ItemNamespace.routinePrefix.count)
            .split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        switch (parts[0], parts.count) {
        case ("newest", 2):
            self.init(kind: .newest, feedKey: parts[1])
        case ("next", 2):
            self.init(kind: .next(count: 1), feedKey: parts[1])
        case ("next", 3):
            // One spelling per rule: a count of one is written without it.
            guard let count = Int(parts[1]), String(count) == parts[1], count != 1 else { return nil }
            self.init(kind: .next(count: count), feedKey: parts[2])
        default:
            return nil
        }
    }

    /// The one spelling of the rule; "next" with one episode carries no count.
    var id: String {
        switch kind {
        case .newest: return "\(ItemNamespace.routinePrefix)newest:\(feedKey)"
        case .next(count: 1): return "\(ItemNamespace.routinePrefix)next:\(feedKey)"
        case .next(let count): return "\(ItemNamespace.routinePrefix)next:\(count):\(feedKey)"
        }
    }

    /// The rule a routine already holds for a show: one rule per show.
    static func ofShow(_ feedKey: String, in itemIds: [String]) -> RoutineRule? {
        itemIds.lazy.compactMap(RoutineRule.init(id:)).first { $0.feedKey == feedKey }
    }

    // MARK: - Resolving

    /// One episode of the show as the resolution needs it. Heard and begun
    /// are the shared judgement (this device, the server, the bridge
    /// between the two homes of a show), handed in by the caller.
    struct Episode: Equatable, Sendable {
        let guid: String
        let pubDate: Double
        let isPlayed: Bool
        let isStarted: Bool
        let isDownloaded: Bool

        init(guid: String, pubDate: Double, isPlayed: Bool = false, isStarted: Bool = false, isDownloaded: Bool = false) {
            self.guid = guid
            self.pubDate = pubDate
            self.isPlayed = isPlayed
            self.isStarted = isStarted
            self.isDownloaded = isDownloaded
        }
    }

    /// Why an entry plays nothing this time; the raw value is its line.
    enum Absence: String, Equatable, Sendable {
        case noEpisodes = "the show has no episodes"
        case newestHeard = "the newest episode is heard"
        case nothingNext = "no unheard episode from where the listener stands"
        case offline = "offline, the episode is not downloaded"
    }

    enum Outcome: Equatable, Sendable {
        /// The episodes in the order they play.
        case play([String])
        case absent(Absence)
    }

    /// What the rule plays now.
    ///
    /// - Newest: the newest episode; a begun one resumes, a heard one makes
    ///   the entry fall out this time.
    /// - Next: the next `count` from where the listener stands
    ///   (`PodcastAutoDownloadRules.nextInOrder`), from the oldest episode
    ///   there is when nothing is heard yet.
    /// - Offline only downloaded episodes play, and only as the rule would
    ///   pick them: the newest when it is downloaded, the next ones up to the
    ///   first that is not, never one further on in its place.
    func resolve(_ episodes: [Episode], online: Bool) -> Outcome {
        guard !episodes.isEmpty else { return .absent(.noEpisodes) }
        let picked: [Episode]
        switch kind {
        case .newest:
            guard let newest = episodes.max(by: { $0.pubDate < $1.pubDate }) else { return .absent(.noEpisodes) }
            if newest.isPlayed { return .absent(.newestHeard) }
            picked = [newest]
        case .next(let count):
            let byGuid = Dictionary(episodes.map { ($0.guid, $0) }, uniquingKeysWith: { first, _ in first })
            let guids = PodcastAutoDownloadRules.nextInOrder(
                episodes.map { .init(guid: $0.guid, pubDate: $0.pubDate) },
                isPlayed: { byGuid[$0]?.isPlayed ?? false },
                isStarted: { byGuid[$0]?.isStarted ?? false },
                isDownloaded: { _ in false },
                limit: count)
            picked = guids.compactMap { byGuid[$0] }
            if picked.isEmpty { return .absent(.nothingNext) }
        }
        guard !online else { return .play(picked.map(\.guid)) }
        let downloaded = picked.prefix { $0.isDownloaded }
        return downloaded.isEmpty ? .absent(.offline) : .play(downloaded.map(\.guid))
    }
}
