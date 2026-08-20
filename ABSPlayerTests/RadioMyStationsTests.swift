// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Testing
import Foundation
@testable import ABSPlayer

/// cb2d1ed: the "My Stations" row — composition, the exclusion fence, and the
/// three-state line.
@Suite struct RadioMyStationsTests {

    private func station(_ id: String, _ name: String? = nil) -> RadioStation {
        RadioStation(id: "radio:rb:\(id)", name: name ?? id,
                     streamURL: "https://s.test/\(id)", homepage: "https://h.test")
    }

    /// The fence the order asks for: a stated preference outranks measured
    /// time. Otherwise the order is unexplainable to whoever set the star.
    @Test func aFavoriteWithoutTimeStandsBeforeANonFavoriteWithTime() {
        let fav = station("fav"), heavy = station("heavy")
        let row = RadioMyStations.composed(
            favorites: [fav], mostPlayed: [heavy],
            seconds: ["radio:rb:heavy": 99_999], excluding: nil, limit: 8)
        #expect(row.map(\.id) == ["radio:rb:fav", "radio:rb:heavy"])
    }

    @Test func withinEachGroupTheLongerListenedComesFirst() {
        let a = station("a"), b = station("b"), c = station("c")
        let row = RadioMyStations.composed(
            favorites: [a, b], mostPlayed: [c],
            seconds: ["radio:rb:a": 100, "radio:rb:b": 900, "radio:rb:c": 5],
            excluding: nil, limit: 8)
        #expect(row.map(\.id) == ["radio:rb:b", "radio:rb:a", "radio:rb:c"])
    }

    /// The second fence: the station of the row BELOW does not appear here.
    /// It is not gone — it stands one row lower.
    @Test func theStationOfTheRowBelowIsLeftOut() {
        let recent = station("recent"), other = station("other")
        let row = RadioMyStations.composed(
            favorites: [recent, other], mostPlayed: [],
            seconds: [:], excluding: "radio:rb:recent", limit: 8)
        #expect(row.map(\.id) == ["radio:rb:other"])
    }

    @Test func theExcludedStationIsTheOneTheRowBelowShows() {
        #expect(RadioMyStations.excludedID(recents: [station("x"), station("y")]) == "radio:rb:x")
        #expect(RadioMyStations.excludedID(recents: []) == nil)
    }

    /// A station in both sources is ONE card, not two.
    @Test func aFavoriteThatIsAlsoMostPlayedAppearsOnce() {
        let both = station("both")
        let row = RadioMyStations.composed(favorites: [both], mostPlayed: [both],
                                           seconds: [:], excluding: nil, limit: 8)
        #expect(row.count == 1)
    }

    @Test func theRowIsCapped() {
        let many = (0..<20).map { station("s\($0)") }
        #expect(RadioMyStations.composed(favorites: many, mostPlayed: [],
                                         seconds: [:], excluding: nil, limit: 8).count == 8)
    }

    // MARK: - The one line, three states

    @Test func aRunningStationShowsItsShow() {
        #expect(RadioMyStations.cardLine(isRunning: true, runningLine: "Wer weiß denn sowas",
                                         seconds: 99_999) == .running("Wer weiß denn sowas"))
    }

    /// The floor is an honesty rule, not decoration: below it we say nothing.
    @Test func belowAnHourTheLineStaysSilent() {
        #expect(RadioMyStations.cardLine(isRunning: false, runningLine: nil, seconds: 3599) == .none)
        #expect(RadioMyStations.cardLine(isRunning: false, runningLine: nil, seconds: 3600)
                == .listened(hours: 1))
        #expect(RadioMyStations.cardLine(isRunning: false, runningLine: nil, seconds: 3600 * 3 + 59)
                == .listened(hours: 3))
    }

    /// A station that has started but sent no title yet must NOT fall back to
    /// its listening time — the line would flip to the show a moment later,
    /// and a card that changes its statement twice in two seconds reads as
    /// broken.
    @Test func aRunningStationWithoutATitleStaysEmptyRatherThanShowingHours() {
        #expect(RadioMyStations.cardLine(isRunning: true, runningLine: nil, seconds: 99_999) == .none)
        #expect(RadioMyStations.cardLine(isRunning: true, runningLine: "", seconds: 99_999) == .none)
    }
}
