// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import ABSPlayer

/// Statistics across a person's own devices: one pot per device, summed on
/// READ. The tests below are ordered by what would hurt most if it broke —
/// double counting first, because it is the failure that looks like a working
/// app with slightly wrong numbers.
struct ListeningStatsSyncTests {

    private let phone = "device-phone"
    private let pad = "device-pad"

    // MARK: - Die Falle, die die Bauform begruendet

    @Test("das eigene Geraet wird NICHT doppelt gezaehlt")
    func ownDeviceIsNotCountedTwice() {
        let local = ListeningStatsData(secondsPerDay: ["2026-08-19": 100])
        // Der eigene Topf in der Wolke ist ein SPIEGEL der lokalen Datei.
        // Wer beide addiert, bekommt eine Zahl, die einfach zu gross ist —
        // und niemandem faellt auf, warum.
        let merged = ListeningStatsSync.merged(
            local: local, ownDeviceId: phone,
            foreign: [phone: ListeningStatsData(secondsPerDay: ["2026-08-19": 100]),
                      pad: ListeningStatsData(secondsPerDay: ["2026-08-19": 40])])
        #expect(merged.secondsPerDay["2026-08-19"] == 140)
    }

    @Test("fremde Geraete addieren sich, je Tag und je Titel")
    func foreignDevicesAddUp() {
        let merged = ListeningStatsSync.merged(
            local: ListeningStatsData(secondsPerDay: ["2026-08-19": 60],
                                      secondsPerItem: ["radio:rb:a": 60]),
            ownDeviceId: phone,
            foreign: [pad: ListeningStatsData(secondsPerDay: ["2026-08-19": 30,
                                                             "2026-08-18": 90],
                                              secondsPerItem: ["radio:rb:a": 30,
                                                               "radio:rb:b": 10])])
        #expect(merged.secondsPerDay == ["2026-08-19": 90, "2026-08-18": 90])
        #expect(merged.secondsPerItem == ["radio:rb:a": 90, "radio:rb:b": 10])
    }

    @Test("ohne fremde Geraete ist die Summe die eigene Datei")
    func singleDeviceIsUnchanged() {
        let local = ListeningStatsData(secondsPerDay: ["2026-08-19": 42],
                                       secondsPerItem: ["radio:rb:a": 42])
        #expect(ListeningStatsSync.merged(local: local, ownDeviceId: phone, foreign: [:]) == local)
    }

    // MARK: - Was reist, und was nicht (die Budget-Trennlinie)

    @Test("nur was KEINE Position hat, reist mit")
    func onlyPositionlessItemsTravel() {
        let data = ListeningStatsData(
            secondsPerDay: ["2026-08-19": 1000],
            secondsPerItem: ["radio:rb:a": 400,       // keine Position -> reist
                             "rss:feed:episode": 300,  // Position reist schon
                             "lva:some-work": 200,     // dito
                             "abs-book-id": 100])      // dito, ueber den Server
        let out = ListeningStatsSync.publishable(data)
        #expect(out.secondsPerDay == ["2026-08-19": 1000], "der Tages-Topf reist ganz")
        #expect(out.secondsPerItem == ["radio:rb:a": 400],
                "Folgen und Buecher tragen ihre Zeit laengst in einem Kanal, der synchronisiert")
    }

    // MARK: - Schluessel

    @Test("die Geraetekennung steht im SCHLUESSEL, nicht im Wert")
    func deviceIdIsPartOfTheKey() {
        let key = ListeningStatsSync.key(forDeviceId: phone)
        #expect(key == "listeningStats.device-phone")
        #expect(ListeningStatsSync.deviceId(fromKey: key) == phone)
        #expect(ListeningStatsSync.deviceId(fromKey: "podcastProgress") == nil)
        #expect(ListeningStatsSync.deviceId(fromKey: "listeningStats.") == nil)
    }

    // MARK: - Verdichtung: benannte Regel, kein stilles Kappen

    @Test("alte Tage fallen zu Monaten zusammen, die Summe bleibt exakt")
    func oldDaysCollapseIntoMonths() {
        let data = ListeningStatsData(secondsPerDay: [
            "2026-08-19": 100,   // heute
            "2026-08-01": 50,    // jung
            "2024-03-04": 30,    // alt
            "2024-03-05": 20,    // alt, selber Monat
            "2023-11-30": 10,    // aelter
        ])
        let out = ListeningStatsSync.compacted(data, todayKey: "2026-08-19")
        #expect(out.secondsPerDay["2026-08-19"] == 100)
        #expect(out.secondsPerDay["2026-08-01"] == 50)
        #expect(out.secondsPerDay["2024-03"] == 50, "beide Maerz-Tage in einem Schluessel")
        #expect(out.secondsPerDay["2023-11"] == 10)
        #expect(out.secondsPerDay["2024-03-04"] == nil)
        // Die eigentliche Zusicherung: nichts geht verloren.
        #expect(out.secondsPerDay.values.reduce(0,+) == data.secondsPerDay.values.reduce(0,+))
    }

    @Test("Verdichtung ist ein Fixpunkt — der zweite Lauf aendert nichts")
    func compactionIsIdempotent() {
        let data = ListeningStatsData(secondsPerDay: ["2024-03-04": 30, "2026-08-19": 100])
        let once = ListeningStatsSync.compacted(data, todayKey: "2026-08-19")
        let twice = ListeningStatsSync.compacted(once, todayKey: "2026-08-19")
        #expect(once == twice)
    }

    @Test("ein Monats-Schluessel kann nie mit einem Tages-Schluessel kollidieren")
    func monthKeysCannotCollide() {
        // 7 Zeichen gegen 10 — die Verdichtung erkennt Tage an der Laenge.
        #expect("2024-03".count == 7 && "2024-03-04".count == 10)
        let out = ListeningStatsSync.compacted(
            ListeningStatsData(secondsPerDay: ["2024-03": 5]), todayKey: "2026-08-19")
        #expect(out.secondsPerDay == ["2024-03": 5], "ein Monat bleibt ein Monat")
    }

    // MARK: - Kappe des Item-Topfs

    @Test("der Item-Topf behaelt die laengsten, nicht die neuesten")
    func itemPotKeepsTheLongest() {
        let items = ["a": 10, "b": 500, "c": 300, "d": 1]
        let out = ListeningStatsSync.cappedItems(items, limit: 2)
        #expect(out == ["b": 500, "c": 300])
        #expect(ListeningStatsSync.cappedItems(items, limit: 10) == items,
                "unter der Kappe bleibt alles unangetastet")
    }

    @Test("Gleichstand kappt stabil, damit zwei Geraete dasselbe behalten")
    func capIsStableOnTies() {
        let items = ["b": 100, "a": 100, "c": 50]
        #expect(ListeningStatsSync.cappedItems(items, limit: 2) == ["a": 100, "b": 100])
    }

    // MARK: - „Haeufig gehoert" rankt nach ZEIT

    private func station(_ id: String) -> RadioStation {
        RadioStation(id: "radio:rb:\(id)", name: id.uppercased(), streamURL: "https://s/\(id)")
    }

    @Test("Zeit schlaegt Startzahl: zwei Stunden gewinnen gegen viele Antipper")
    func timeBeatsStarts() {
        let stations = [station("a"), station("b")]
        // a wurde zwanzigmal angetippt und nie gehoert, b einmal zwei Stunden.
        let ranked = RadioRanking.mostPlayed(
            stations: stations,
            counts: ["radio:rb:a": 20, "radio:rb:b": 1],
            seconds: ["radio:rb:a": 30, "radio:rb:b": 7200],
            limit: 8)
        #expect(ranked.map(\.id) == ["radio:rb:b", "radio:rb:a"],
                "genau der Fall, wegen dem das Mass gewechselt wurde")
    }

    @Test("Uebergangsphase: ohne gemessene Zeit traegt der Startzaehler")
    func fallbackCarriesTheTransition() {
        let stations = [station("a"), station("b")]
        // Direkt nach dem Update kennt niemand Sekunden — die Reihe darf
        // deswegen nicht leer sein.
        let ranked = RadioRanking.mostPlayed(
            stations: stations, counts: ["radio:rb:a": 3, "radio:rb:b": 9],
            seconds: [:], limit: 8)
        #expect(ranked.map(\.id) == ["radio:rb:b", "radio:rb:a"])
    }

    @Test("gemessene Zeit schlaegt den Rueckfall, egal wie gross dessen Zahl ist")
    func measuredOutranksTheFallback() {
        let stations = [station("a"), station("b")]
        // a hat 99 Starts und keine Zeit, b eine einzige gemessene Minute.
        let ranked = RadioRanking.mostPlayed(
            stations: stations, counts: ["radio:rb:a": 99, "radio:rb:b": 0],
            seconds: ["radio:rb:b": 60], limit: 8)
        #expect(ranked.map(\.id) == ["radio:rb:b", "radio:rb:a"],
                "der Rueckfall verschwindet fuer einen Sender, sobald Zeit da ist")
    }

    @Test("ein Sender ohne beides steht in keiner Reihe")
    func unknownStationsStayOut() {
        #expect(RadioRanking.mostPlayed(stations: [station("a")], counts: [:],
                                        seconds: [:], limit: 8).isEmpty)
    }
}
/// The shared derivation "how much did I listen to this show". One place, two
/// callers (recommendation seed and statistics) — two derivations of the same
/// number would disagree on screen, which is worse than either being wrong.
struct ListeningByClassTests {

    private func showId(_ episodeId: String) -> String? {
        AppStorageKeys.podcastShowId(forEpisodeId: episodeId)
    }

    @Test("Folgen summieren sich zu ihrer Sendung")
    func episodesSumIntoTheirShow() {
        let defaults: [String: Any] = [
            "localPosition.rss:feedA:ep1": [600.0, 1.7e12],
            "localPosition.rss:feedA:ep2": [300.0, 1.7e12],
            "localPosition.rss:feedB:ep1": [100.0, 1.7e12],
            "localPosition.abspod:show1:ep1": [900.0, 1.7e12],
        ]
        let out = ListeningByClass.shows(in: defaults, showId: showId)
        #expect(out["rss:feedA"] == 900)
        #expect(out["rss:feedB"] == 100)
        #expect(out["abspod:show1"] == 900)
    }

    @Test("was keine Sendung ist, zaehlt nicht mit")
    func nonPodcastEntriesAreIgnored() {
        let defaults: [String: Any] = [
            "localPosition.radio:rb:a": [600.0, 1.7e12],   // Live-Strom
            "localPosition.lva:work": [600.0, 1.7e12],     // Katalog
            "localPosition.abs-book": [600.0, 1.7e12],     // Server-Buch
            "somethingElse": [600.0, 1.7e12],
        ]
        #expect(ListeningByClass.shows(in: defaults, showId: showId).isEmpty)
    }

    @Test("eine negative oder kaputte Position erfindet keine Zeit")
    func brokenEntriesContributeNothing() {
        let defaults: [String: Any] = [
            "localPosition.rss:feedA:ep1": [-50.0, 1.7e12],
            "localPosition.rss:feedA:ep2": [10.0],            // zu kurz
            "localPosition.rss:feedA:ep3": "kein Array",
        ]
        #expect(ListeningByClass.shows(in: defaults, showId: showId)["rss:feedA"] == 0)
    }

    @Test("Top-N sortiert nach Zeit, Gleichstand stabil")
    func topIsStable() {
        let out = ListeningByClass.top(["b": 100, "a": 100, "c": 500, "d": 0], limit: 3)
        #expect(out.map(\.id) == ["c", "a", "b"], "0 faellt raus, Gleichstand alphabetisch")
    }
}

/// Die Logo-Diagnose. Ihr Wert haengt an EINER Unterscheidung: „die Kette hat
/// nichts gefunden" und „die Kette ist nie fertig geworden" sehen auf dem
/// Bildschirm gleich aus (Buchstaben), sind aber verschiedene Ursachen mit
/// verschiedenen Fixes.
struct RadioLogoReportTests {

    @Test("nie fertig geworden ist etwas anderes als kein Treffer")
    func unfinishedIsNotTheSameAsNoHit() {
        let rows = RadioLogoReport.rows(
            stations: [(id: "a", name: "A", faviconURL: "https://a/f.png"),
                       (id: "b", name: "B", faviconURL: nil),
                       (id: "c", name: "C", faviconURL: nil)],
            chainResults: ["a": (hasLogo: true, attempted: true),
                           "b": (hasLogo: false, attempted: true)])
        #expect(rows.first { $0.id == "a" }?.chainResolved == true)
        #expect(rows.first { $0.id == "b" }?.chainAttempted == true)
        #expect(rows.first { $0.id == "b" }?.chainResolved == false)
        // c fehlt in den Ergebnissen — genau der Fall, der den Verdacht traegt.
        #expect(rows.first { $0.id == "c" }?.chainAttempted == false)
    }

    @Test("die Kopfzeile nennt die Zahl, auf die es ankommt")
    func summaryNamesTheDecidingNumber() {
        let rows = RadioLogoReport.rows(
            stations: [(id: "a", name: "A", faviconURL: "https://a/f.png"),
                       (id: "b", name: "B", faviconURL: nil)],
            chainResults: ["a": (hasLogo: true, attempted: true)])
        let text = RadioLogoReport.text(rows)
        #expect(text.contains("NIE FERTIG GEWORDEN:  1"))
        #expect(text.contains("Kette mit Logo:       1"))
        #expect(text.contains("mit Favicon-Adresse:  1"))
    }

    @Test("ein leerer Bestand meldet Nullen statt zu verschwinden")
    func emptyStateReportsZeros() {
        let text = RadioLogoReport.text(RadioLogoReport.rows(stations: [], chainResults: [:]))
        #expect(text.contains("Sender in den Reihen: 0"))
    }
}
#endif
