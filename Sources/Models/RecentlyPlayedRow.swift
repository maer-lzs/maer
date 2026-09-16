// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation

/// ONE "Recently Played" row for albums AND stations. Both make the
/// same promise (start it again, no position to resume), and both
/// wear the same tile.
///
/// **Deliberately a pure TIME order, not a fair interleave.** "Recently
/// Played" is a truth row: whoever listened to radio for three days sees
/// radio. That is the opposite of "Recently Added", where the fair
/// interleave exists so the music library's fresher timestamps cannot take
/// every slot. Please do not "align" the two, the difference is the point.
///
/// **The boundary is position, not media type** (order point 3): an album
/// with a real listening position belongs in Continue and must not appear
/// here as a duplicate. Stations never have a position. A live stream has
/// no place to return to. So they are always eligible.
nonisolated enum RecentlyPlayedRow {
    enum Entry: Equatable, Hashable {
        case album(id: String)
        case station(id: String)
        /// A catalogue title started as an album track (netlabel album,
        /// shellac side, Jamendo track). Its own case rather than `.album`,
        /// because the two resolve through different providers.
        case catalogTrack(id: String)
    }

    /// Merge by time. Entries WITHOUT a known time keep their source order
    /// and rank behind everything dated. A missing timestamp (a station
    /// heard before the row existed, an album the server only sorted) is not a reason to
    /// invent one.
    ///
    /// - Parameters:
    ///   - albums: album ids in source order (server's "recently played").
    ///   - albumTimes: id → last played, where known.
    ///   - continued: album ids that Continue already shows. Dropped here.
    ///   - stations: station ids in MRU order.
    ///   - stationTimes: id → last played, where known.
    ///   - catalog: catalogue ids started as album tracks, newest first.
    ///   - catalogTimes: id → last played, from the entry that carries the form.
    static func merged(albums: [String], albumTimes: [String: Double],
                       continued: Set<String>,
                       stations: [String], stationTimes: [String: Double],
                       catalog: [String] = [], catalogTimes: [String: Double] = [:],
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
        // The `continued` filter applies here too. It is the same promise: a
        // title Continue shows is not offered a second time. In practice the
        // switch already keeps these two apart, so this is the belt beside the
        // braces, not the mechanism.
        for (index, id) in catalog.enumerated() where !continued.contains(id) {
            ranked.append(Ranked(entry: .catalogTrack(id: id), time: catalogTimes[id], order: index))
        }
        let dated = ranked.filter { $0.time != nil }
            .sorted { ($0.time ?? 0) > ($1.time ?? 0) }
        let undated = ranked.filter { $0.time == nil }
            .sorted { $0.order < $1.order }
        return (dated + undated).prefix(limit).map(\.entry)
    }

    /// "Is this time known?", asked ONCE for every argument of `merged`.
    ///
    /// A non-positive stamp is not a time. The store writes a zero on
    /// purpose: `ForeignListeningState.verdict` adopts a foreign position
    /// whose source carried no moment and stamps it zero, so that any real
    /// later moment beats it. Read as a time, that zero is the epoch, which
    /// ranks ahead of everything undated. So the zero already means
    /// "unknown" where it is written, and this is where the reader agrees
    /// with the writer.
    ///
    /// Seconds in, seconds out. The callers that hold milliseconds divide
    /// first, because the question is about the value, not about its unit.
    static func knownTime(_ seconds: Double) -> Double? {
        seconds > 0 ? seconds : nil
    }

    /// The `albumTimes` argument, built from the progress the music surfaces
    /// hold. Every surface asks this instead of writing the mapping again.
    static func albumTimes(_ progress: [String: BookProgress]) -> [String: Double] {
        progress.compactMapValues { knownTime($0.lastUpdate / 1000) }
    }

    /// The `catalogTimes` argument. The first entry per id decides, exactly
    /// as the hand-written mapping did; whether that entry carries a time is
    /// then the one question above.
    static func catalogTimes(_ extras: [ContinueSources.Extra]) -> [String: Double] {
        Dictionary(extras.map { ($0.id, $0.updatedAtMs / 1000) },
                   uniquingKeysWith: { first, _ in first })
            .compactMapValues(knownTime)
    }
}
