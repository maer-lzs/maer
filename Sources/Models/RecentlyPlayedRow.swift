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
        /// An own list whose home is music, by the moment it was last heard.
        case ownList(id: String)
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
                       ownLists: [String: Double] = [:],
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
        // An own list stands only by its moment, so it is always dated.
        for (index, list) in ownLists.sorted(by: { $0.key < $1.key }).enumerated() {
            ranked.append(Ranked(entry: .ownList(id: list.key), time: list.value, order: index))
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

    /// The `albumTimes` argument where the surface holds no server
    /// progress (the music tab): the moment THIS device last heard each
    /// album, from the listening stock (`[position, tsMs, …]`). An album
    /// heard only elsewhere stays undated and keeps its source order.
    static func deviceTimes(_ ids: [String], positions: [String: [Double]]) -> [String: Double] {
        var times: [String: Double] = [:]
        for id in ids {
            guard let entry = positions[id], entry.count >= 2,
                  let time = knownTime(entry[1] / 1000) else { continue }
            times[id] = time
        }
        return times
    }

    /// The `albumTimes` argument every surface passes (Start, the music
    /// tab, the mixed page and the car): the server's moment of an album
    /// where its progress names one, since it knows what other devices
    /// heard; else the moment this device last heard it. An album neither
    /// knows stays undated and keeps its source order.
    static func albumMoments(_ ids: [String], server: [String: BookProgress],
                             positions: [String: [Double]]) -> [String: Double] {
        deviceTimes(ids, positions: positions).merging(albumTimes(server)) { _, served in served }
    }

    /// The music ids that may stand in the row beside the server's shelf:
    /// a started album (a finished one is the shelf's to show), and every
    /// server playlist with a moment, started, finished or shuffled from
    /// its card (`plays`, ms). "Remove from Listen Again" holds until a
    /// newer moment, the marker of the Continue cards.
    /// The two kinds of a music key the row asks for; the caller asks the
    /// key's server and answers with one of them or none.
    enum MusicKind { case album, playlist }

    static func musicCandidates(progress: [String: BookProgress], kind: (String) -> MusicKind?,
                                plays: [String: Double], hidden: [String: Double]) -> [String] {
        var moments: [String: Double] = [:]
        for (id, value) in progress {
            switch kind(id) {
            case .album where value.isStarted: moments[id] = value.lastUpdate
            case .playlist where value.lastUpdate > 0 || value.fraction > 0: moments[id] = value.lastUpdate
            default: continue
            }
        }
        for (id, ms) in plays where kind(id) == .playlist {
            moments[id] = max(moments[id] ?? 0, ms)
        }
        return moments.filter { !ContinueHidden.isHidden(id: $0.key, lastUpdate: $0.value, markers: hidden) }
            .map(\.key).sorted()
    }

    /// The `ownLists` argument: own lists whose home is music, by the
    /// moment this device last heard them, in seconds.
    static func ownListTimes(_ lists: [(id: String, home: PlaylistHome)], plays: [String: Double],
                             hidden: [String: Double]) -> [String: Double] {
        var times: [String: Double] = [:]
        for list in lists where list.home == .music {
            guard let ms = plays[list.id], let time = knownTime(ms / 1000),
                  !ContinueHidden.isHidden(id: list.id, lastUpdate: ms, markers: hidden) else { continue }
            times[list.id] = time
        }
        return times
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
