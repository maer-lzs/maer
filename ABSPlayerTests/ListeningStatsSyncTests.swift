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
}
#endif
