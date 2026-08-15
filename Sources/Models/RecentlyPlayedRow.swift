// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation

/// P14: ONE "Recently Played" row for albums AND stations — both make the
/// same promise (start it again, no position to resume), and since P9 both
/// wear the same tile.
///
/// **Deliberately a pure TIME order, not a fair interleave.** "Recently
/// Played" is a truth row: whoever listened to radio for three days sees
/// radio. That is the opposite of "Recently Added", where the fair
/// interleave exists so the music library's fresher timestamps cannot take
/// every slot — please do not "align" the two, the difference is the point.
///
/// **The boundary is position, not media type** (order point 3): an album
/// with a real listening position belongs in Continue and must not appear
/// here as a duplicate. Stations never have a position — a live stream has
/// no place to return to — so they are always eligible.
nonisolated enum RecentlyPlayedRow {
    enum Entry: Equatable, Hashable {
        case album(id: String)
        case station(id: String)
    }

    /// Merge by time. Entries WITHOUT a known time keep their source order
    /// and rank behind everything dated — a missing timestamp (a station
    /// heard before P14, an album the server only sorted) is not a reason to
    /// invent one.
    ///
    /// - Parameters:
    ///   - albums: album ids in source order (server's "recently played").
    ///   - albumTimes: id → last played, where known.
    ///   - continued: album ids that Continue already shows — dropped here.
    ///   - stations: station ids in MRU order.
    ///   - stationTimes: id → last played, where known.
    static func merged(albums: [String], albumTimes: [String: Double],
                       continued: Set<String>,
                       stations: [String], stationTimes: [String: Double],
                       limit: Int) -> [Entry] {
        struct Ranked {
            let entry: Entry
            let time: Double?
            let order: Int
        }
        var ranked: [Ranked] = []
        for (index, id) in albums.enumerated() where !continued.contains(id) {
            ranked.append(Ranked(entry: .album(id: id), time: albumTimes[id], order: index))
        }
        for (index, id) in stations.enumerated() {
            ranked.append(Ranked(entry: .station(id: id), time: stationTimes[id], order: index))
        }
        let dated = ranked.filter { $0.time != nil }
            .sorted { ($0.time ?? 0) > ($1.time ?? 0) }
        let undated = ranked.filter { $0.time == nil }
            .sorted { $0.order < $1.order }
        return (dated + undated).prefix(limit).map(\.entry)
    }
}
