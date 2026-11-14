// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Testing
import Foundation
@testable import Maer

/// The Jamendo row: a reported failure does not decay into an
/// empty answer, and the first good answer of the day carries the day.
struct JamendoRowTests {

    /// Jamendo reports errors INSIDE a 200: the envelope says `failed` and
    /// carries code and message. Read as `results ?? []`, a
    /// throttle could not be told apart from an empty chart, the line
    /// „hat ohne Titel geantwortet" stood for something that was never an empty
    /// answer. Checked against a literal of the REAL form.
    @Test("a reported failure THROWS instead of decaying into an empty list")
    func aStatedFailureThrowsInsteadOfDecaying() throws {
        // The red probe carries `results: []` TOO: exactly then the old
        // form silently returned an empty list.
        let fehlschlag = Data("""
        {"headers":{"status":"failed","code":5,"error_message":"Suspended or unknown client Id","warnings":"","results_count":0},"results":[]}
        """.utf8)
        #expect(throws: JamendoDecoder.JamendoFailure.self) {
            _ = try JamendoDecoder.decodeTracks(fehlschlag)
        }
        do {
            _ = try JamendoDecoder.decodeTracks(fehlschlag)
        } catch let failure as JamendoDecoder.JamendoFailure {
            #expect(failure.code == 5, "der gemessene Code reist nicht mit")
            #expect(failure.message?.contains("client Id") == true)
        }

        // A good answer still delivers its titles.
        let gut = Data("""
        {"headers":{"status":"success","code":0,"error_message":"","results_count":1},"results":[{"id":"168","name":"J'm'e FPM","artist_name":"TriFace","image":"","audio":"https://example.org/a.mp3","shareurl":"https://example.org","duration":183}]}
        """.utf8)
        let tracks = try JamendoDecoder.decodeTracks(gut)
        #expect(tracks.count == 1)
        #expect(tracks.first?.name == "J'm'e FPM")

        // And a REALLY empty good answer stays an empty list:
        // empty is a meaningful value, not an error.
        let leer = Data("""
        {"headers":{"status":"success","code":0,"error_message":"","results_count":0},"results":[]}
        """.utf8)
        #expect(try JamendoDecoder.decodeTracks(leer).isEmpty)
    }

    /// The Jamendo track in the day store: the source form survives the
    /// write path, and its rule differs from the other
    /// surfaces, so that a window or ordering change makes old answers
    /// unfindable.
    @Test("the Jamendo track survives the day and carries its own rule")
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
        // dayBound checks against NOW; the entry of `heute` is visible to the
        // test only through `load` with the same point in time.
        let geladen = CatalogShelfSource.shelfStore.load(
            defaults: defaults, now: heute, rule: CatalogShelfSource.shelfRule(forId:))
        #expect(geladen[id]??.tracks?.first?.id == "168",
                "die Quellform ueberlebt den Schreibweg nicht")
        _ = tag

        // The rule is that of the Jamendo track, not empty and not that of a
        // different surface. An empty rule would keep every old entry
        // alive, no matter what changes.
        #expect(CatalogShelfSource.shelfRule(forId: id) == JamendoClient.popularRule)
        #expect(!JamendoClient.popularRule.isEmpty)
        #expect(CatalogShelfSource.shelfRule(forId: id)
                != CatalogShelfSource.shelfRule(
                    forId: CatalogShelfSource.stockId(surface: "librivox", shelf: "popular")))
    }

    /// Only a GOOD answer is written down. The fence sits at the
    /// source text of the write site: the store call stands in the
    /// non-empty branch, after the emptiness check.
    @Test("only a good answer is written down", .needsTheSources)
    func onlyAGoodAnswerIsWrittenDown() throws {
        let text = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("Sources/ViewModels/FreeCatalogLoader.swift"),
            encoding: .utf8)
            .split(whereSeparator: \.isWhitespace).joined()
        // Order in the condensed text: first the emptiness check with
        // its line, THEN the store call. If it stood before, an empty
        // answer would be written too.
        let leerPruefung = try #require(text.range(of: "ifrows.freeMusic.isEmpty"))
        let schreibstelle = try #require(text.range(of: "shelfStore.store"))
        #expect(leerPruefung.lowerBound < schreibstelle.lowerBound,
                "die Schreibstelle steht vor der Leer-Pruefung")
        // And the day is read BEFORE the network.
        // The call now also names the store it reads (`defaults: dayStore`).
        let tagLesen = try #require(text.range(of: "storedDay(surface:JamendoClient.daySurface"))
        #expect(tagLesen.lowerBound < leerPruefung.lowerBound,
                "die Reihe fragt das Netz, bevor sie den Tag liest")
    }
}
