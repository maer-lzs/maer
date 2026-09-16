// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// Die Zuletzt-gehört-Reihe für Alben UND Sender. Reine Zeitfolge,
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
        // Drei Sender vor dem Album. Genau das, was eine faire
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

    // MARK: - Die Null ist keine Zeit

    /// Der Sender-Zweig, gefahren durch den SPEICHER statt durch ein
    /// Woerterbuch von Hand: der Uebernahme-Weg schreibt die Null, der
    /// Lese-Weg muss sie als unbekannt herausgeben, und die Reihe muss den
    /// Sender dann bei den UNDATIERTEN fuehren.
    ///
    /// Der Zeuge misst die RANGFOLGE, nicht die Abbildung. Ohne den Filter
    /// zaehlt die Null als datiert und der Sender steht VOR einem Sender
    /// ohne jeden Eintrag, also mitten in der Reihe.
    @Test("ein Sender ohne Moment steht bei den undatierten, nicht in der Mitte")
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
        // Genau die Gestalt, die der Uebernahme-Weg erzeugt: die Zeiten
        // kommen aus dem Blob, einer davon ohne Zeitstempel.
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
        // Datiert zuerst, danach die beiden Undatierten in Quell-Reihenfolge.
        #expect(out == [.station(id: dated.id), .station(id: noEntry.id),
                        .station(id: zero.id)])
    }

    /// Der Katalog-Zweig. Die Null entsteht dort, wo eine fremde Position
    /// ohne Moment uebernommen wird, und der Eintrag traegt sie bis in die
    /// Reihe.
    @Test("ein Katalog-Titel ohne Moment steht bei den undatierten")
    func aCatalogTrackWithoutAMomentRanksWithTheUndated() {
        // Der Dritte OHNE jeden Eintrag ist der eigentliche Massstab: ohne
        // ihn sagt der Fall nur, dass die Abbildung filtert, und die
        // Rangfolge zweier Eintraege sieht mit und ohne Filter gleich aus.
        // Genau daran ist die erste Fassung dieses Zeugen bei der Rot-Probe
        // NICHT gerissen.
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
        // Datiert zuerst, danach die beiden Undatierten in Quell-Reihenfolge.
        #expect(out == [.catalogTrack(id: dated.id), .catalogTrack(id: noEntry),
                        .catalogTrack(id: zero.id)])
    }

    /// Die Alben-Haelfte beantwortete die Frage schon richtig, aber an jeder
    /// Flaeche neu. Jetzt an einer Stelle, mit demselben Ergebnis.
    @Test("die Alben-Haelfte gibt dieselbe Antwort und gibt sie an einer Stelle")
    func albumTimesAnswerTheSameQuestionOnce() {
        let progress = [
            "alb-dated": BookProgress(fraction: 0.2, isFinished: false, lastUpdate: 500_000),
            "alb-zero": BookProgress(fraction: 0.2, isFinished: false, lastUpdate: 0)
        ]
        let times = RecentlyPlayedRow.albumTimes(progress)
        #expect(times["alb-dated"] == 500)
        #expect(times["alb-zero"] == nil)
    }

    /// Die Regel selbst, in beide Richtungen. Eine negative Zeit ist so
    /// wenig eine Zeit wie eine Null.
    @Test("nicht-positiv heisst unbekannt, positiv bleibt unveraendert")
    func theRuleItself() {
        #expect(RecentlyPlayedRow.knownTime(0) == nil)
        #expect(RecentlyPlayedRow.knownTime(-1) == nil)
        #expect(RecentlyPlayedRow.knownTime(0.5) == 0.5)
        #expect(RecentlyPlayedRow.knownTime(500) == 500)
    }

    /// Der Zaun: BEIDE Flaechen nennen die Tueren, und KEINE baut die
    /// Abbildung noch einmal von Hand. Beide sind namentlich genannt, damit
    /// eine dritte nicht stumm danebenlaeuft.
    @Test("keine Flaeche beantwortet die Frage ein zweites Mal")
    func noSurfaceAnswersTheQuestionASecondTime() throws {
        let surfaces = ["HomeView.swift", "MixedMediaPage.swift"]
        var seen: Set<String> = []
        for file in ProjectFileIntegrityTests.sourceFiles() {
            let text = try String(contentsOf: file, encoding: .utf8)
            guard text.contains("RecentlyPlayedRow.merged(") else { continue }
            let leaf = file.lastPathComponent
            seen.insert(leaf)
            #expect(surfaces.contains(leaf),
                    "eine dritte Flaeche baut die Reihe: \(leaf)")
            #expect(text.contains("RecentlyPlayedRow.albumTimes("),
                    "\(leaf) baut die Album-Zeiten selbst")
            #expect(text.contains("RecentlyPlayedRow.catalogTimes("),
                    "\(leaf) baut die Katalog-Zeiten selbst")
            #expect(text.contains("RadioStore.recentTimes("),
                    "\(leaf) holt die Sender-Zeiten nicht aus dem Speicher")
            // Die Handschrift, die es vorher war: eine Abbildung auf
            // `lastUpdate` oder `updatedAtMs` an der Aufrufstelle.
            #expect(!text.contains("$0.lastUpdate / 1000"),
                    "\(leaf) rechnet die Album-Zeit wieder selbst um")
            #expect(!text.contains("$0.updatedAtMs / 1000"),
                    "\(leaf) rechnet die Katalog-Zeit wieder selbst um")
        }
        #expect(seen == Set(surfaces), "Flaechen gefunden: \(seen.sorted())")
    }
}
#endif
