// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation

/// The rules for tidying up after the automatic download. The part that must
/// be provable without a screen.
///
/// The binding condition: **the cleanup only ever touches what the automatism
/// itself downloaded.** That is a property of the DATA (an id the automatism
/// recorded), never a guess from the age of a file. Someone who downloaded an
/// episode by hand for a flight must not lose it because a background pass
/// thought it looked old.
///
/// Deliberately source-neutral: nothing here knows what a podcast is, so the
/// same rules can carry "keep this playlist offline" later.
nonisolated enum PodcastAutoDownloadRules {
    /// How long a finished download stays before it goes. A day: long enough
    /// to go back into an episode just heard, short enough that a daily show
    /// does not pile up finished files.
    static let keepAfterFinish: TimeInterval = 24 * 3600

    struct Item: Equatable, Sendable {
        let id: String
        let isFinished: Bool
        /// When the finished state was last written (seconds since 1970).
        let finishedAt: Double

        init(id: String, isFinished: Bool, finishedAt: Double) {
            self.id = id
            self.isFinished = isFinished
            self.finishedAt = finishedAt
        }
    }

    /// Which episodes the automatism fetches next: **the first N unheard, in
    /// order**. The direction of listening THROUGH a show from its start.
    ///
    /// The rule used to be "the newest N since enabling", which serves news
    /// shows and nobody who works a backlog: whoever hears a show from the
    /// beginning got the episodes farthest from where they actually are.
    /// Played and already-downloaded episodes fall out; the cleanup rules
    /// below stay untouched, they answer a different question.
    struct Candidate: Equatable, Sendable {
        let guid: String
        let pubDate: Double

        init(guid: String, pubDate: Double) {
            self.guid = guid
            self.pubDate = pubDate
        }
    }

    ///
    /// **From where the listener IS**: the run starts at the latest
    /// episode that was heard or begun, not at the first unheard one. Someone
    /// at episode 100 whose episodes 1 to 99 never carried a mark in this app
    /// (heard elsewhere, before switching) got episode 1; an episode skipped
    /// on the way is the listener's choice and is not fetched back. The begun
    /// episode itself counts when it is not finished. Without any mark the
    /// run starts at the beginning, as before.
    ///
    /// **One episode out of the row is not the place**: the anchor
    /// is where the listener's run ends, see `anchorIndex`. A taste of the
    /// newest episode, or one special heard far ahead, no longer moves it.
    static func nextInOrder(_ episodes: [Candidate],
                            isPlayed: (String) -> Bool,
                            isStarted: (String) -> Bool = { _ in false },
                            isDownloaded: (String) -> Bool,
                            limit: Int) -> [String] {
        let ordered = episodes.sorted { $0.pubDate < $1.pubDate }
        let marked = ordered.map { isPlayed($0.guid) || isStarted($0.guid) }
        let anchor = anchorIndex(marked: marked).map { ordered[$0].pubDate }
        return ordered
            .filter { episode in anchor.map { episode.pubDate >= $0 } ?? true }
            .filter { !isPlayed($0.guid) && !isDownloaded($0.guid) }
            .prefix(limit)
            .map(\.guid)
    }

    /// Unheard episodes a run may pass over and still be one run: a skipped
    /// episode or two is the listener's choice, a gap of hundreds is not a
    /// row.
    static let runGap = 3

    /// "Begun" for the anchor means at least this far in, the same half
    /// minute the Continue row asks of a title. Ten seconds of the newest
    /// episode to hear what it is about is not where anyone stands.
    static let startedAtLeast: Double = 30

    /// Whether a mark is begun in that sense: in progress and at least
    /// `startedAtLeast` in. The auto-download and a routine's rule ask this.
    static func isStarted(_ mark: ProgressMark.PlayState, duration: Double) -> Bool {
        guard case .inProgress(_, let remaining) = mark else { return false }
        return duration - remaining >= startedAtLeast
    }

    /// Where the listener stands, as an index into the episodes in order of
    /// publication (`marked` says which are heard or begun). Marks with at
    /// most `gap` unmarked episodes between them form a run. The anchor is
    /// the end of the LATEST run of two or more: someone who jumped ahead
    /// and kept going stands there. With no such run it is the end of the
    /// EARLIEST run: of two lone marks, the one far ahead is the outlier
    /// (the newest episode tried, a special heard), and the earlier one is
    /// the place in the row. Nil without any mark.
    static func anchorIndex(marked: [Bool], gap: Int = runGap) -> Int? {
        var runs: [(last: Int, count: Int)] = []
        for (index, isMarked) in marked.enumerated() where isMarked {
            if let current = runs.last, index - current.last - 1 <= gap {
                runs[runs.count - 1] = (index, current.count + 1)
            } else {
                runs.append((index, 1))
            }
        }
        return (runs.last { $0.count >= 2 } ?? runs.first)?.last
    }

    /// Which downloads may go now. Never anything outside `ownedByAutomation`.
    static func expired(_ items: [Item],
                        ownedByAutomation: Set<String>,
                        now: Double,
                        keepFor: TimeInterval = keepAfterFinish) -> [String] {
        items.filter { item in
            ownedByAutomation.contains(item.id)
                && item.isFinished
                && item.finishedAt > 0
                && now - item.finishedAt >= keepFor
        }.map(\.id)
    }

    /// Which way the automatism reads a show: the newest episodes, or on
    /// from where the listener stands. How a person listens, so it travels.
    enum Direction: String, CaseIterable, Sendable {
        case newest
        case inOrder
    }

    /// How many episodes of one show the automatism keeps downloaded, and
    /// how many when nobody chose.
    static let keepChoices: [Int] = [1, 3, 5, 10]
    static let keepByDefault = 3

    /// One of the automatism's own downloads of a show. Protected is one
    /// that is begun or playing: it never goes because of a count.
    struct Owned: Equatable, Sendable {
        let id: String
        let pubDate: Double
        let isProtected: Bool

        init(id: String, pubDate: Double, isProtected: Bool) {
            self.id = id
            self.pubDate = pubDate
            self.isProtected = isProtected
        }
    }

    struct Hold: Equatable, Sendable {
        /// To download, best first.
        let fetch: [String]
        /// Own downloads to delete, farthest from the direction first.
        let drop: [String]
    }

    /// What the automatism holds of one show. `wanted` are the episodes the
    /// direction asks for, best first; the first `limit` of them are the
    /// target. What of the target is missing is fetched. Own downloads
    /// outside the target go, farthest from the direction first (newest: the
    /// oldest; in order: the newest, the one farthest from where the
    /// listener stands), and only as many as keep the own downloads at
    /// `limit`. A protected one never goes; a fetch waits while protected
    /// ones fill the count. A download by hand is never own, so it is not
    /// in `own` and never goes.
    static func hold(wanted: [String], isDownloaded: (String) -> Bool,
                     own: [Owned], direction: Direction, limit: Int) -> Hold {
        let target = Array(wanted.prefix(max(0, limit)))
        let targetIds = Set(target)
        let missing = target.filter { !isDownloaded($0) }
        let farthestFirst = own
            .filter { !targetIds.contains($0.id) && !$0.isProtected }
            .sorted { direction == .newest ? $0.pubDate < $1.pubDate : $0.pubDate > $1.pubDate }
        let excess = max(0, own.count + missing.count - limit)
        let drop = Array(farthestFirst.prefix(excess))
        let room = max(0, limit - (own.count - drop.count))
        return Hold(fetch: Array(missing.prefix(room)), drop: drop.map(\.id))
    }

    /// Ids the automatism no longer has to remember: everything it deleted,
    /// plus everything that is not on the device any more (deleted by hand.
    /// The note would otherwise grow forever).
    static func forget(ownedByAutomation: Set<String>,
                       deleted: [String],
                       stillDownloaded: Set<String>) -> Set<String> {
        ownedByAutomation.subtracting(deleted).intersection(stillDownloaded)
    }
}
