// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation

/// New episodes of a show into Up Next, chosen per show: at the top, at the
/// end, or not at all. Pure: what arrived, where each show wants it, since
/// when, and which episodes are still unheard come in; the episodes for the
/// top and for the end go out, each block in the order the episodes appeared.
nonisolated enum UpNextAuto {
    /// Where a show's new episodes go. Off is the default.
    enum Placement: String, CaseIterable, Sendable {
        case off, top, end
    }

    /// The stored choice per show and for all shows, which travel, and the
    /// moment each went on, which stays on the device.
    static func key(_ showId: String) -> String { "podcastUpNextAdd.\(showId)" }
    static let generalKey = "podcastUpNextAddAll"
    static func sinceKey(_ showId: String) -> String { "podcastUpNextAddSince.\(showId)" }
    static let generalSinceKey = "podcastUpNextAddAllSince"

    /// An episode a refresh brought for the first time.
    struct Arrival: Equatable, Sendable {
        let id: String
        let showId: String
        /// Milliseconds since 1970, as the feed gives it.
        let pubDate: Double
    }

    /// What goes into Up Next, each block oldest first.
    struct Plan: Equatable, Sendable {
        var top: [String] = []
        var end: [String] = []
        var isEmpty: Bool { top.isEmpty && end.isEmpty }
    }

    /// The episodes of `merged` whose ids `stored` did not hold. A show seen
    /// for the first time brings nothing: that is its backlog, not news.
    static func arrivals(stored: PodcastShow?, merged: PodcastShow) -> [Arrival] {
        guard let stored else { return [] }
        let known = Set(stored.episodes.map(\.guid))
        return merged.episodes.filter { !known.contains($0.guid) }
            .map { Arrival(id: $0.guid, showId: merged.id, pubDate: $0.pubDate) }
    }

    /// Both conditions hold for every episode that goes in: its id arrived
    /// for the first time, AND it appeared after the show's choice was
    /// switched on (`since`, milliseconds). A feed that moves or hands out
    /// new ids brings its whole backlog as arrivals, and only the second
    /// condition keeps that out. An episode heard or begun stays out, and so
    /// does one already queued.
    static func plan(_ arrivals: [Arrival],
                     placement: (String) -> Placement,
                     since: (String) -> Double?,
                     isUnheard: (String) -> Bool,
                     isQueued: (String) -> Bool) -> Plan {
        var plan = Plan()
        var seen = Set<String>()
        let ordered = arrivals.sorted { ($0.pubDate, $0.id) < ($1.pubDate, $1.id) }
        for arrival in ordered where seen.insert(arrival.id).inserted {
            let spot = placement(arrival.showId)
            guard spot != .off,
                  let since = since(arrival.showId), arrival.pubDate > since,
                  isUnheard(arrival.id), !isQueued(arrival.id) else { continue }
            if spot == .top { plan.top.append(arrival.id) } else { plan.end.append(arrival.id) }
        }
        return plan
    }
}
