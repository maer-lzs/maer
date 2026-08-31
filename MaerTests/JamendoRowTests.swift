// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Testing
import Foundation
@testable import Maer

/// Die Jamendo-Reihe: ein gemeldeter Fehlschlag verfaellt nicht zu einer
/// leeren Antwort, und die erste gute Antwort des Tages traegt den Tag.
struct JamendoRowTests {

    /// Jamendo meldet Fehler IN einer 200: der Umschlag sagt `failed` und
    /// traegt Code und Meldung. Als `results ?? []` gelesen, war eine
    /// Drosselung von einem leeren Chart nicht zu unterscheiden — die Zeile
    /// „hat ohne Titel geantwortet" stand fuer etwas, das nie eine leere
    /// Antwort war. Gegen ein Literal der ECHTEN Form geprueft.
    @Test("ein gemeldeter Fehlschlag WIRFT, statt zu einer leeren Liste zu verfallen")
    func aStatedFailureThrowsInsteadOfDecaying() throws {
        // Die Rot-Probe traegt `results: []` MIT: genau dann gab die alte
        // Form still eine leere Liste zurueck.
        let fehlschlag = Data("""
        {"headers":{"status":"failed","code":5,"error_message":"Suspended or unknown client Id","warnings":"","results_count":0},"results":[]}
        """.utf8)
        #expect(throws: JamendoClient.JamendoFailure.self) {
            _ = try JamendoClient.decodeTracks(fehlschlag)
        }
        do {
            _ = try JamendoClient.decodeTracks(fehlschlag)
        } catch let failure as JamendoClient.JamendoFailure {
            #expect(failure.code == 5, "der gemessene Code reist nicht mit")
            #expect(failure.message?.contains("client Id") == true)
        }

        // Eine gute Antwort liefert weiter ihre Titel.
        let gut = Data("""
        {"headers":{"status":"success","code":0,"error_message":"","results_count":1},"results":[{"id":"168","name":"J'm'e FPM","artist_name":"TriFace","image":"","audio":"https://example.org/a.mp3","shareurl":"https://example.org","duration":183}]}
        """.utf8)
        let tracks = try JamendoClient.decodeTracks(gut)
        #expect(tracks.count == 1)
        #expect(tracks.first?.name == "J'm'e FPM")

        // Und eine WIRKLICH leere gute Antwort bleibt eine leere Liste:
        // leer ist ein bedeutungsvoller Wert, kein Fehler.
        let leer = Data("""
        {"headers":{"status":"success","code":0,"error_message":"","results_count":0},"results":[]}
        """.utf8)
        #expect(try JamendoClient.decodeTracks(leer).isEmpty)
    }

    /// Die Jamendo-Spur im Tages-Speicher: die Quellform ueberlebt den
    /// Schreibweg, und ihre Regel unterscheidet sich von den uebrigen
    /// Flaechen, damit ein Fenster- oder Ordnungs-Wechsel alte Antworten
    /// unauffindbar macht.
    @Test("die Jamendo-Spur ueberlebt den Tag und traegt ihre eigene Regel")
    func theJamendoLaneSurvivesItsDay() throws {
        let suite = "jamendo-tag-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let heute = Date(timeIntervalSince1970: 1_756_000_000)

        let id = CatalogShelfSource.stockId(surface: JamendoClient.daySurface,
                                            shelf: "popular")
        let track = JamendoTrack(id: "168", name: "T", artist_name: "A", image: nil,
                                 audio: "https://example.org/a.mp3", shareurl: nil,
                                 duration: 183)
        #expect(CatalogShelfSource.shelfStore.store(
            .found(CatalogShelfSource.ShelfStock(total: nil, books: nil, docs: nil,
                                                 tracks: [track])),
            for: id, rule: JamendoClient.popularRule, defaults: defaults, now: heute))

        let tag = CatalogShelfSource.storedDay(surface: JamendoClient.daySurface,
                                               defaults: defaults)
        // dayBound prueft gegen JETZT; der Eintrag von `heute` ist fuer den
        // Test nur ueber `load` mit demselben Zeitpunkt sichtbar.
        let geladen = CatalogShelfSource.shelfStore.load(
            defaults: defaults, now: heute, rule: CatalogShelfSource.shelfRule(forId:))
        #expect(geladen[id]??.tracks?.first?.id == "168",
                "die Quellform ueberlebt den Schreibweg nicht")
        _ = tag

        // Die Regel ist die der Jamendo-Spur, nicht leer und nicht die einer
        // anderen Flaeche. Eine leere Regel hielte jeden alten Eintrag am
        // Leben, egal was sich aendert.
        #expect(CatalogShelfSource.shelfRule(forId: id) == JamendoClient.popularRule)
        #expect(!JamendoClient.popularRule.isEmpty)
        #expect(CatalogShelfSource.shelfRule(forId: id)
                != CatalogShelfSource.shelfRule(
                    forId: CatalogShelfSource.stockId(surface: "librivox", shelf: "popular")))
    }

    /// Nur eine GUTE Antwort wird niedergeschrieben. Der Zaun sitzt am
    /// Quelltext der Schreibstelle: der Speicher-Aufruf steht im
    /// Nicht-leer-Zweig, nach der Leer-Pruefung.
    @Test("nur eine gute Antwort wird niedergeschrieben")
    func onlyAGoodAnswerIsWrittenDown() throws {
        let text = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("Sources/Views/FreeCatalogRows.swift"),
            encoding: .utf8)
            .split(whereSeparator: \.isWhitespace).joined()
        // Reihenfolge im zusammengezogenen Text: erst die Leer-Pruefung mit
        // ihrer Zeile, DANN der Speicher-Aufruf. Staende er davor, schriebe
        // auch eine leere Antwort.
        let leerPruefung = try #require(text.range(of: "ifrows.freeMusic.isEmpty"))
        let schreibstelle = try #require(text.range(of: "shelfStore.store"))
        #expect(leerPruefung.lowerBound < schreibstelle.lowerBound,
                "die Schreibstelle steht vor der Leer-Pruefung")
        // Und der Tag wird VOR dem Netz gelesen.
        let tagLesen = try #require(text.range(of: "storedDay(surface:JamendoClient.daySurface)"))
        #expect(tagLesen.lowerBound < leerPruefung.lowerBound,
                "die Reihe fragt das Netz, bevor sie den Tag liest")
    }
}
