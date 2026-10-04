// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// Statistics across a person's own devices: one pot per device, summed on
/// READ. The tests below are ordered by what would hurt most if it broke.
/// Double counting first, because it is the failure that looks like a working
/// app with slightly wrong numbers.
struct ListeningStatsSyncTests {

    private let phone = "device-phone"
    private let pad = "device-pad"

    // MARK: - Die Falle, die die Bauform begruendet

    @Test("das eigene Geraet wird NICHT doppelt gezaehlt")
    func ownDeviceIsNotCountedTwice() {
        let local = ListeningStatsData(secondsPerDay: ["2026-08-19": 100])
        // Der eigene Topf in der Wolke ist ein SPIEGEL der lokalen Datei.
        // Wer beide addiert, bekommt eine Zahl, die einfach zu gross ist.
        // Und niemandem faellt auf, warum.
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

    // MARK: - Die Haeufig-gehoert-Reihe rankt nach ZEIT

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
        // Direkt nach dem Update kennt niemand Sekunden. Die Reihe darf
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

    // MARK: - Die Uebernahme des eigenen Topfs

    /// The day table could not be read, the item table was: the start holds
    /// the read items. The own pot carries one live item. No adoption, so no
    /// read item is removed by the next write.
    @Test("Tage unlesbar, Titel gelesen, eigener Topf mit einem Live-Titel: keine Uebernahme, kein gelesener Titel geht")
    func aReadTableIsNeverReplacedByThePot() {
        let read = ListeningStatsData(secondsPerDay: [:], secondsPerItem: ["abs:book": 900, "radio:rb:x": 60])
        let base = RowBase<ListeningStatsData>.unknown(seen: read)
        let pot = ListeningStatsData(secondsPerDay: ["2026-10-04": 120], secondsPerItem: ["radio:rb:x": 60])
        #expect(ListeningStatsSync.adoptedOwnPot(base: base, own: read, pot: pot) == nil, "the pot replaced a read table")
        // What the next write would remove with the stock it keeps: nothing.
        #expect(base.map(\.secondsPerItem).previous(for: read.secondsPerItem).isEmpty)
        #expect(ListeningStatsSync.adoptedOwnPot(base: .known(read), own: read, pot: pot) == nil)
    }

    /// Nothing could be read (a fresh file after a reset, or the read failed
    /// as a whole): the own pot comes back, merged into what this run already
    /// counted, per key the larger value.
    @Test("nichts gelesen: der eigene Topf kommt zurueck, zusammengefuehrt mit dem schon Gezaehlten")
    func nothingReadMergesThePot() {
        let pot = ListeningStatsData(secondsPerDay: ["2026-10-03": 3600, "2026-10-04": 120],
                                     secondsPerItem: ["radio:rb:x": 60])
        let counted = ListeningStatsData(secondsPerDay: ["2026-10-04": 300], secondsPerItem: [:])
        let merged = ListeningStatsSync.adoptedOwnPot(base: .unknown(seen: nil), own: counted, pot: pot)
        #expect(merged == ListeningStatsData(secondsPerDay: ["2026-10-03": 3600, "2026-10-04": 300],
                                             secondsPerItem: ["radio:rb:x": 60]))
        #expect(ListeningStatsSync.adoptedOwnPot(base: .fresh, own: ListeningStatsData(), pot: pot) == pot)
        #expect(ListeningStatsSync.adoptedOwnPot(base: .fresh, own: ListeningStatsData(), pot: nil) == nil)
        #expect(ListeningStatsSync.adoptedOwnPot(base: .fresh, own: pot, pot: pot) == nil, "a second run changes nothing")
    }

    /// The measured loss: the day table could not be read, its row holds
    /// 2400 from a save after the last publish, the own pot 1200. The pot
    /// is shown and published, but no write carries it over the unread row;
    /// only what this run counted above it goes.
    @Test("Tabelle unlesbar, Zeile 2400, Topf 1200: der Topf zeigt sich, aber kein Schrieb traegt ihn ueber die ungelesene Zeile")
    func aPotOverUnreadRowsIsHeldOutOfEveryWrite() {
        let day = "2026-10-04"
        let pot = ListeningStatsData(secondsPerDay: [day: 1200], secondsPerItem: ["radio:rb:x": 60])
        let counted = ListeningStatsData(secondsPerDay: [day: 300], secondsPerItem: [:])
        let stats = ListeningStatsStore(carrier: KeyValueStatsCarrier(store: InMemoryCloudStore()))
        stats.testAdopt(own: counted, base: .unknown(seen: nil), pot: pot)
        #expect(stats.testOwnData.secondsPerDay[day] == 1200, "the precondition: the pot was adopted for the display")
        #expect(stats.testOwnData.secondsPerItem["radio:rb:x"] == 60)
        #expect(stats.testWriteSnapshot == counted, "a pot value reaches the write over the unread row")
        #expect(!ListeningStatsSync.adoptionWrites(.unknown(seen: nil)))
        #expect(ListeningStatsSync.adoptionWrites(.fresh), "a fresh file takes the pot as a write")
    }

    /// What lies above the held part, per key; nothing at or below it.
    @Test("ueber dem gehaltenen Teil bleibt je Schluessel nur der Rest, nichts darunter")
    func aboveKeepsOnlyTheRest() {
        let held = ListeningStatsData(secondsPerDay: ["a": 100, "b": 50], secondsPerItem: ["x": 10])
        let stock = ListeningStatsData(secondsPerDay: ["a": 130, "b": 50, "c": 7], secondsPerItem: ["x": 5, "y": 3])
        #expect(ListeningStatsSync.above(held, in: stock)
                == ListeningStatsData(secondsPerDay: ["a": 30, "c": 7], secondsPerItem: ["y": 3]))
        #expect(ListeningStatsSync.above(ListeningStatsData(), in: stock) == stock)
    }
}
/// The shared derivation "how much did I listen to this show". One place, two
/// callers (recommendation seed and statistics). Two derivations of the same
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

/// Die Logo-Diagnose. Ihr Wert haengt an EINER Unterscheidung: eine Kette,
/// die nichts gefunden hat, und eine, die nie fertig wurde, sehen auf dem
/// Bildschirm gleich aus (Buchstaben), sind aber verschiedene Ursachen mit
/// verschiedenen Fixes.
struct RadioLogoReportTests {

    @Test("nie fertig geworden ist etwas anderes als kein Treffer")
    func unfinishedIsNotTheSameAsNoHit() {
        let rows = RadioLogoReport.rows(
            stations: [(id: "a", name: "A", faviconURL: "https://a/f.png"),
                       (id: "b", name: "B", faviconURL: nil),
                       (id: "c", name: "C", faviconURL: nil)],
            chainResults: ["a": (hasLogo: true, attempted: true, resolvedAt: 1000),
                           "b": (hasLogo: false, attempted: true, resolvedAt: 1000)],
            now: 1200)
        #expect(rows.first { $0.id == "a" }?.chainResolved == true)
        #expect(rows.first { $0.id == "b" }?.chainAttempted == true)
        #expect(rows.first { $0.id == "b" }?.chainResolved == false)
        // c fehlt in den Ergebnissen. Genau der Fall, der den Verdacht traegt.
        #expect(rows.first { $0.id == "c" }?.chainAttempted == false)
    }

    @Test("die Kopfzeile nennt die Zahl, auf die es ankommt")
    func summaryNamesTheDecidingNumber() {
        let rows = RadioLogoReport.rows(
            stations: [(id: "a", name: "A", faviconURL: "https://a/f.png"),
                       (id: "b", name: "B", faviconURL: nil)],
            chainResults: ["a": (hasLogo: true, attempted: true, resolvedAt: 1000)],
            now: 1200)
        let text = RadioLogoReport.text(rows)
        #expect(text.contains("OHNE ERGEBNIS:        1"))
        #expect(text.contains("Kette mit Logo:       1"))
        #expect(text.contains("mit Favicon-Adresse:  1"))
    }

    @Test("ein leerer Bestand meldet Nullen statt zu verschwinden")
    func emptyStateReportsZeros() {
        let text = RadioLogoReport.text(RadioLogoReport.rows(stations: [], chainResults: [:], now: 0))
        #expect(text.contains("Sender in den Reihen: 0"))
    }

    /// "OHNE ERGEBNIS" is one of THREE causes, and the report must
    /// name which. Queued, transport-failed, or given up. They look the same
    /// on screen and need different fixes.
    @Test("OHNE ERGEBNIS trennt Warteschlange, Fehlschlag und Aufgabe")
    func noResultNamesItsCause() {
        let stations: [(id: String, name: String, faviconURL: String?)] = [
            (id: "w", name: "W", faviconURL: nil),
            (id: "f", name: "F", faviconURL: nil),
            (id: "g", name: "G", faviconURL: nil),
            (id: "n", name: "N", faviconURL: nil)]
        let text = RadioLogoReport.text(RadioLogoReport.rows(
            stations: stations, chainResults: [:], now: 0,
            waiting: ["w"], sessionFailed: ["f", "g"], gaveUp: ["g"]))
        #expect(text.contains("W · Favicon nein · Kette OHNE ERGEBNIS — in Arbeit (Warteschlange)"))
        #expect(text.contains("F · Favicon nein · Kette OHNE ERGEBNIS — versucht, nichts gebucht (Transport scheiterte)"))
        #expect(text.contains("G · Favicon nein · Kette OHNE ERGEBNIS — aufgegeben (2 Fehlversuche diese Sitzung)"))
        #expect(text.contains("N · Favicon nein · Kette OHNE ERGEBNIS — nie versucht"))
    }

    /// Ids shorten to the FIRST characters after the
    /// prefix. The v1-UUID tail is an import batch's shared node field, six
    /// different stations can end identically there.
    @Test("Kurz-id nimmt den Anfang nach dem Praefix, nie das Ende")
    func shortIDTakesTheHead() {
        #expect(RadioLogoReport.shortID("radio:rb:9606f727-0601-11e8-ae97-52543be04c81")
                == "9606f727-0601…")
        #expect(RadioLogoReport.shortID("kurz") == "kurz")
    }
}
#endif

/// The mini player offers nothing that is finished by its own
/// knowledge. Judged by the NUMBERS, and only on evidence.
@Suite struct StandbyFinishedTests {

    @Test("fertig nach Zahlen wird entladen; offen bleibt")
    func finishedByNumbersClears() {
        let done = ListeningStore.mark(from: [3599, 1_000, 3600], source: .backup)
        #expect(PlayerCoordinator.standbyCountsAsFinished(done))
        let open = ListeningStore.mark(from: [1200, 1_000, 3600], source: .backup)
        #expect(!PlayerCoordinator.standbyCountsAsFinished(open))
    }

    @Test("ohne Dauer oder ohne Eintrag wird NIE entladen — nur auf Beleg")
    func noEvidenceKeepsTheStandby() {
        #expect(!PlayerCoordinator.standbyCountsAsFinished(nil))
        let durationless = ListeningStore.mark(from: [1200, 1_000], source: .flushed)
        #expect(!PlayerCoordinator.standbyCountsAsFinished(durationless))
    }
}

/// The diagnosis pot list never reports the own device as foreign. Measured
/// on both real devices ("fremde Töpfe: 2" with exactly two devices): the
/// merge rule skipped the own mirror, the overview did not.
@Suite struct ForeignPotOverviewTests {

    @Test("the own pot never appears in the foreign list")
    func ownPotIsSkipped() {
        let pots = [
            "device-phone": ListeningStatsData(secondsPerDay: ["2026-08-22": 100],
                                               secondsPerItem: ["radio:rb:x": 60]),
            "device-pad": ListeningStatsData(secondsPerDay: ["2026-08-22": 200]),
        ]
        let list = ListeningStatsSync.overview(pots: pots, ownDeviceId: "device-phone")
        #expect(list.map(\.device) == ["device-pad"])
        #expect(list.first?.daySeconds == 200)
        #expect(list.first?.radioSeconds == 0)
    }

    @Test("a genuinely foreign orphan pot stays visible")
    func orphanStaysVisible() {
        let pots = ["device-old": ListeningStatsData(secondsPerDay: ["2026-01-01": 50])]
        let list = ListeningStatsSync.overview(pots: pots, ownDeviceId: "device-new")
        #expect(list.map(\.device) == ["device-old"])
    }
}
