// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// The recently-played row for albums AND stations. Pure time order,
/// NO fair interleaving (truth row), the limit is a position.
struct RecentlyPlayedRowTests {
    @Test("pure time order: whoever only listens to radio sees radio")
    func pureTimeOrderNeverInterleaves() {
        let out = RecentlyPlayedRow.merged(
            albums: ["alb1"], albumTimes: ["alb1": 100],
            continued: [],
            stations: ["st1", "st2", "st3"],
            stationTimes: ["st1": 400, "st2": 300, "st3": 200],
            limit: 10)
        // Three stations before the album. Exactly what a fair
        // interleaving would prevent and what is RIGHT here.
        #expect(out == [.station(id: "st1"), .station(id: "st2"),
                        .station(id: "st3"), .album(id: "alb1")])
    }

    @Test("play an album, then a station ⇒ station first")
    func acceptanceCase() {
        let out = RecentlyPlayedRow.merged(
            albums: ["alb"], albumTimes: ["alb": 1000],
            continued: [],
            stations: ["st"], stationTimes: ["st": 2000],
            limit: 10)
        #expect(out == [.station(id: "st"), .album(id: "alb")])
    }

    @Test("Resuming wins: no duplicate on one page")
    func continuedAlbumsAreNotDuplicated() {
        let out = RecentlyPlayedRow.merged(
            albums: ["running", "done"],
            albumTimes: ["running": 5000, "done": 1000],
            continued: ["running"],
            stations: [], stationTimes: [:], limit: 10)
        #expect(out == [.album(id: "done")])
    }

    @Test("without a timestamp none is invented: source order, at the back")
    func undatedKeepSourceOrderBehindDated() {
        let out = RecentlyPlayedRow.merged(
            albums: ["a1", "a2"], albumTimes: [:],
            continued: [],
            stations: ["s1"], stationTimes: ["s1": 10],
            limit: 10)
        #expect(out == [.station(id: "s1"), .album(id: "a1"), .album(id: "a2")])
        // And the limit also holds the row length.
        #expect(RecentlyPlayedRow.merged(albums: ["a1", "a2", "a3"], albumTimes: [:],
                                         continued: [], stations: [], stationTimes: [:],
                                         limit: 2).count == 2)
    }

    // MARK: - Zero is not a time

    /// The station branch, driven through the STORE instead of a
    /// hand-made dictionary: the takeover path writes the zero, the
    /// read path must hand it out as unknown, and the row must then
    /// put the station among the UNDATED.
    ///
    /// The witness measures the RANKING, not the mapping. Without the filter
    /// the zero counts as dated and the station sits BEFORE a station
    /// without any entry, so in the middle of the row.
    @Test("a station without a moment sits with the undated, not in the middle")
    func aStationWithoutAMomentRanksWithTheUndated() {
        let name = "recently-played-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let noEntry = RadioStation(id: "radio:rb:none", name: "Ohne Eintrag",
                                   streamURL: "https://none.example/s")
        let zero = RadioStation(id: "radio:rb:zero", name: "Mit Null",
                                streamURL: "https://zero.example/s")
        let dated = RadioStation(id: "radio:rb:dated", name: "Mit Zeit",
                                 streamURL: "https://dated.example/s")
        // Exactly the shape the takeover path produces: the times
        // come from the blob, one of them without a timestamp.
        RadioStore.replaceRecents([noEntry, zero, dated],
                                  times: [zero.id: 0, dated.id: 500],
                                  defaults: defaults)
        let times = RadioStore.recentTimes(defaults: defaults)
        #expect(times[dated.id] == 500, "die echte Zeit bleibt unangetastet")
        #expect(times[zero.id] == nil, "die Null verlaesst den Speicher als unbekannt")

        let out = RecentlyPlayedRow.merged(
            albums: [], albumTimes: [:], continued: [],
            stations: [noEntry.id, zero.id, dated.id], stationTimes: times,
            limit: 10)
        // Dated first, then the two undated in source order.
        #expect(out == [.station(id: dated.id), .station(id: noEntry.id),
                        .station(id: zero.id)])
    }

    /// The catalog branch. The zero arises where a foreign position
    /// is taken over without a moment, and the entry carries it into the
    /// row.
    @Test("a catalog title without a moment sits with the undated")
    func aCatalogTrackWithoutAMomentRanksWithTheUndated() {
        // The third one WITHOUT any entry is the real yardstick: without
        // it the case only says that the mapping filters, and the
        // ranking of two entries looks the same with and without the filter.
        // That is exactly why the first version of this witness did NOT
        // fail in the red probe.
        let noEntry = "lva:ohne#1"
        let zero = ContinueSources.Extra(id: "lva:zero#1", position: 30,
                                         updatedAtMs: 0, duration: 600)
        let dated = ContinueSources.Extra(id: "jam:dated", position: 30,
                                          updatedAtMs: 500_000, duration: 600)
        let times = RecentlyPlayedRow.catalogTimes([zero, dated])
        #expect(times[dated.id] == 500, "Millisekunden werden zu Sekunden")
        #expect(times[zero.id] == nil)

        let out = RecentlyPlayedRow.merged(
            albums: [], albumTimes: [:], continued: [],
            stations: [], stationTimes: [:],
            catalog: [noEntry, zero.id, dated.id], catalogTimes: times, limit: 10)
        // Dated first, then the two undated in source order.
        #expect(out == [.catalogTrack(id: dated.id), .catalogTrack(id: noEntry),
                        .catalogTrack(id: zero.id)])
    }

    /// The album half already answered the question correctly, but anew on every
    /// surface. Now in one place, with the same result.
    @Test("the album half gives the same answer and gives it in one place")
    func albumTimesAnswerTheSameQuestionOnce() {
        let progress = [
            "alb-dated": BookProgress(fraction: 0.2, isFinished: false, lastUpdate: 500_000),
            "alb-zero": BookProgress(fraction: 0.2, isFinished: false, lastUpdate: 0)
        ]
        let times = RecentlyPlayedRow.albumTimes(progress)
        #expect(times["alb-dated"] == 500)
        #expect(times["alb-zero"] == nil)
    }

    @Test("the time of a server album comes from this device's set, otherwise it stays undated")
    func deviceTimesComeFromTheStock() {
        let positions: [String: [Double]] = [
            "sub:album:a": [0, 2_000_000],
            "sub:album:b": [12, 0],
            "sub:album:c": [3],
        ]
        let times = RecentlyPlayedRow.deviceTimes(["sub:album:a", "sub:album:b", "sub:album:c", "sub:album:d"],
                                                  positions: positions)
        #expect(times == ["sub:album:a": 2000], "a zero stamp, a short entry or none is no time")
        // Merged: the dated catalogue title and album by time, the
        // undated albums behind them in the server's order.
        let merged = RecentlyPlayedRow.merged(albums: ["sub:album:d", "sub:album:a"], albumTimes: times,
                                              continued: [], stations: [], stationTimes: [:],
                                              catalog: ["jam:1"], catalogTimes: ["jam:1": 3000], limit: 10)
        #expect(merged == [.catalogTrack(id: "jam:1"), .album(id: "sub:album:a"), .album(id: "sub:album:d")])
    }

    /// The rule itself, in both directions. A negative time is as
    /// little a time as a zero.
    @Test("non-positive means unknown, positive stays unchanged")
    func theRuleItself() {
        #expect(RecentlyPlayedRow.knownTime(0) == nil)
        #expect(RecentlyPlayedRow.knownTime(-1) == nil)
        #expect(RecentlyPlayedRow.knownTime(0.5) == 0.5)
        #expect(RecentlyPlayedRow.knownTime(500) == 500)
    }

    /// The fence: BOTH surfaces name the doors, and NEITHER builds the
    /// mapping again by hand. Both are named, so that
    /// a third does not run along silently beside them.
    @Test("no surface answers the question a second time", .needsTheSources)
    func noSurfaceAnswersTheQuestionASecondTime() throws {
        // The music tab's row is asked by the tab and the car in one place.
        let surfaces = ["HomeView.swift", "MixedMediaPage.swift", "SharedRows.swift"]
        var seen: Set<String> = []
        for file in ProjectFileIntegrityTests.sourceFiles() {
            let text = try String(contentsOf: file, encoding: .utf8)
            guard text.contains("RecentlyPlayedRow.merged(") else { continue }
            let leaf = file.lastPathComponent
            seen.insert(leaf)
            #expect(surfaces.contains(leaf),
                    "eine dritte Flaeche baut die Reihe: \(leaf)")
            // The music tab holds no server progress: its album times
            // come from the device's stock, through the one door for that.
            #expect(text.contains("RecentlyPlayedRow.albumTimes(") || text.contains("RecentlyPlayedRow.deviceTimes("),
                    "\(leaf) baut die Album-Zeiten selbst")
            #expect(text.contains("RecentlyPlayedRow.catalogTimes("),
                    "\(leaf) baut die Katalog-Zeiten selbst")
            // Stations only where the row carries them; the music tab
            // passes none.
            #expect(text.contains("RadioStore.recentTimes(") || text.contains("stations: [], stationTimes: [:]"),
                    "\(leaf) holt die Sender-Zeiten nicht aus dem Speicher")
            // The hand-made form it used to be: a mapping onto
            // `lastUpdate` or `updatedAtMs` at the call site.
            #expect(!text.contains("$0.lastUpdate / 1000"),
                    "\(leaf) rechnet die Album-Zeit wieder selbst um")
            #expect(!text.contains("$0.updatedAtMs / 1000"),
                    "\(leaf) rechnet die Katalog-Zeit wieder selbst um")
        }
        #expect(seen == Set(surfaces), "Flaechen gefunden: \(seen.sorted())")
    }
}
#endif
