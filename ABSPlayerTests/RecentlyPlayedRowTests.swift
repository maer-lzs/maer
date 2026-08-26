// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import ABSPlayer

/// Die Zuletzt-gehört-Reihe für Alben UND Sender — reine Zeitfolge,
/// KEINE faire Verschränkung (Wahrheits-Reihe), Grenze ist Position.
struct RecentlyPlayedRowTests {
    @Test("reine Zeitfolge: wer nur Radio hoert, sieht Radio")
    func pureTimeOrderNeverInterleaves() {
        let out = RecentlyPlayedRow.merged(
            albums: ["alb1"], albumTimes: ["alb1": 100],
            continued: [],
            stations: ["st1", "st2", "st3"],
            stationTimes: ["st1": 400, "st2": 300, "st3": 200],
            limit: 10)
        // Drei Sender vor dem Album — genau das, was eine faire
        // Verschraenkung verhindern wuerde und was hier RICHTIG ist.
        #expect(out == [.station(id: "st1"), .station(id: "st2"),
                        .station(id: "st3"), .album(id: "alb1")])
    }

    @Test("die Abnahme: Album spielen, dann Sender ⇒ Sender zuerst")
    func acceptanceCase() {
        let out = RecentlyPlayedRow.merged(
            albums: ["alb"], albumTimes: ["alb": 1000],
            continued: [],
            stations: ["st"], stationTimes: ["st": 2000],
            limit: 10)
        #expect(out == [.station(id: "st"), .album(id: "alb")])
    }

    @Test("Fortsetzen gewinnt: keine Dublette auf einer Seite")
    func continuedAlbumsAreNotDuplicated() {
        let out = RecentlyPlayedRow.merged(
            albums: ["running", "done"],
            albumTimes: ["running": 5000, "done": 1000],
            continued: ["running"],
            stations: [], stationTimes: [:], limit: 10)
        #expect(out == [.album(id: "done")])
    }

    @Test("ohne Zeitstempel wird keine erfunden — Quellordnung, hinten an")
    func undatedKeepSourceOrderBehindDated() {
        let out = RecentlyPlayedRow.merged(
            albums: ["a1", "a2"], albumTimes: [:],
            continued: [],
            stations: ["s1"], stationTimes: ["s1": 10],
            limit: 10)
        #expect(out == [.station(id: "s1"), .album(id: "a1"), .album(id: "a2")])
        // Und die Grenze haelt auch die Reihenlaenge ein.
        #expect(RecentlyPlayedRow.merged(albums: ["a1", "a2", "a3"], albumTimes: [:],
                                         continued: [], stations: [], stationTimes: [:],
                                         limit: 2).count == 2)
    }
}
#endif
