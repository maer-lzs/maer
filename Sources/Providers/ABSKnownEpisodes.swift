// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation

/// The episode ids this device knew of each Audiobookshelf show, so a
/// refresh can tell what arrived even after a cold start: the server's
/// shows are held only in memory, and without this the first refresh of a
/// start would have nothing to compare with. One row per show, written only
/// for a refresh the provider adopts. A show met for the first time is its
/// baseline and brings nothing; a show the server no longer names loses its
/// row with the next adopted refresh.
@MainActor
final class ABSKnownEpisodes {
    private let keeper: RowKeeper<[String]>?
    private(set) var known: [String: Set<String>] = [:]

    /// `database` nil keeps the sets in memory only.
    init(database: MaerDatabase?) {
        keeper = database.map { RowKeeper(database: $0, table: .absKnownEpisodes, label: "ABSKNOWN") }
        guard let keeper else { return }
        known = (keeper.startNow() ?? [:]).mapValues(Set.init)
        // Rows read after a failed start: a show this run has not met yet
        // takes them, one it met keeps what this run saw.
        keeper.adopt = { [weak self] rows in
            guard let self else { return }
            for (show, ids) in rows where self.known[show] == nil { self.known[show] = Set(ids) }
        }
    }

    /// The arrivals of an adopted refresh against what this device knew; the
    /// new sets are kept. The server names every episode of a show on each
    /// refresh, so its list replaces the set.
    func adopt(_ shows: [PodcastShow]) -> [(show: PodcastShow, arrivals: [UpNextAuto.Arrival])] {
        var found: [(show: PodcastShow, arrivals: [UpNextAuto.Arrival])] = []
        var next: [String: Set<String>] = [:]
        for show in shows {
            let arrivals = UpNextAuto.arrivals(known: known[show.id], show: show)
            if !arrivals.isEmpty { found.append((show, arrivals)) }
            next[show.id] = Set(show.episodes.map(\.guid))
        }
        guard next != known else { return found }
        known = next
        keeper?.write(emptying: .refused) { [weak self] in self?.known.mapValues { $0.sorted() } }
        return found
    }

    /// The server left the device: what it named is no baseline for the
    /// next server or account, whose first refresh is its own baseline.
    func forget() {
        guard !known.isEmpty else { return }
        known = [:]
        keeper?.write(emptying: .allowed) { [weak self] in self?.known.mapValues { $0.sorted() } }
    }

    /// Waits for every queued write of the rows (tests).
    func awaitPendingWrites() async {
        await keeper?.awaitPendingWrites()
    }
}
