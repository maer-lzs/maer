// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation

/// "My Stations" — the radio tab's first row, fed from TWO sources
/// that used to be two rows: marked favorites and the stations with the most
/// measured listening time.
///
/// The separation that stays: "Recently Played" is a STATE, "My Stations" is a
/// PREFERENCE. Two truths do not belong in one row, so the recent station keeps
/// its own row below — and is therefore left out here, one row lower rather
/// than gone. On the full page behind the chevron it reappears: there is no
/// neighbouring row there to duplicate it.
nonisolated enum RadioMyStations {
    /// Favorites first, each group by listening time. A favorite is a stated
    /// preference and outranks measured time — otherwise a starred station
    /// that rarely runs would sink below one the user never chose, and the
    /// order would be unexplainable to the person who set the star.
    static func composed(favorites: [RadioStation], mostPlayed: [RadioStation],
                         seconds: [String: Int], excluding excluded: String?,
                         limit: Int) -> [RadioStation] {
        guard limit > 0 else { return [] }
        let favoriteIDs = Set(favorites.map(\.id))
        var seen = Set<String>()
        if let excluded { seen.insert(excluded) }

        func byTime(_ stations: [RadioStation]) -> [RadioStation] {
            stations.enumerated()
                .sorted { a, b in
                    let sa = seconds[a.element.id] ?? 0, sb = seconds[b.element.id] ?? 0
                    // Ties keep the incoming order — the sources already rank
                    // meaningfully, and a second criterion here would be a
                    // rule nobody could name.
                    return sa == sb ? a.offset < b.offset : sa > sb
                }
                .map(\.element)
        }

        let ordered = byTime(favorites) + byTime(mostPlayed.filter { !favoriteIDs.contains($0.id) })
        return ordered.filter { seen.insert($0.id).inserted }.prefix(limit).map { $0 }
    }

    /// The station of the row below, which this row leaves out. Nil when there
    /// is none — then nothing is excluded.
    static func excludedID(recents: [RadioStation]) -> String? { recents.first?.id }

    /// The card's one line, in three states. It is ONE line with a fixed
    /// height, not two — the height must not depend on which state is showing.
    enum CardLine: Equatable {
        /// The station is playing: the running show.
        case running(String)
        /// Not playing, and enough time measured to be worth saying.
        case listened(hours: Int)
        /// Nothing to say — the height stays reserved.
        case none
    }

    /// Below this we say NOTHING rather than a number.
    ///
    /// The per-station seconds only exist since the statistics train. Without
    /// a floor almost every card would read "0 minutes" for weeks, and on a
    /// marked favorite that rarely runs it would stay there — a number that
    /// looks like a reproach and explains nothing. Show what you know, stay
    /// silent where you do not.
    static let listenedFloor = 3600

    static func cardLine(isRunning: Bool, runningLine: String?, seconds: Int) -> CardLine {
        if isRunning, let runningLine, !runningLine.isEmpty { return .running(runningLine) }
        // A running station without a title yet keeps the line EMPTY rather
        // than falling back to its listening time: the line would flip to the
        // show a moment later, and a card that changes its statement twice in
        // two seconds reads as broken.
        if isRunning { return .none }
        guard seconds >= listenedFloor else { return .none }
        return .listened(hours: seconds / 3600)
    }
}
