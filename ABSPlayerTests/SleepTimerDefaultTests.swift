// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Testing
import Foundation
@testable import ABSPlayer

/// Der Einschlaf-Zeitgeber merkt sich die Dauer, mit der er zuletzt
/// gestartet wurde. Wer jeden Abend dieselben dreissig Minuten setzt, findet
/// sie oben, statt jedes Mal dieselbe Zeile zu treffen.
struct SleepTimerDefaultTests {

    @Test("nichts gemerkt ist kein Angebot, und eine Null wird nie gemerkt")
    func nothingRememberedIsNoOffer() {
        let key = AppStorageKeys.sleepTimerLastMinutes
        let vorher = UserDefaults.standard.object(forKey: key)
        defer {
            if let vorher { UserDefaults.standard.set(vorher, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
        }
        UserDefaults.standard.removeObject(forKey: key)
        #expect(AppStorageKeys.sleepTimerRemembered == nil,
                "ein leerer Speicher bietet eine Dauer an, die es nie gab")

        // Eine Null ist keine Dauer. Ohne diese Klausel boete das Menue
        // „Wieder: 0 min" an, sobald irgendetwas eine Null hineinschreibt.
        AppStorageKeys.rememberSleepTimer(minutes: 0)
        #expect(AppStorageKeys.sleepTimerRemembered == nil,
                "eine Null ist als Vorgabe gemerkt worden")

        AppStorageKeys.rememberSleepTimer(minutes: 30)
        #expect(AppStorageKeys.sleepTimerRemembered == 30)
        // Rot-Probe am Instrument: die Merkstelle nimmt auch eine ANDERE
        // Dauer an. Ein Speicher, der immer dieselbe Zahl liefert, meldete
        // die Zeile darueber genauso gruen.
        AppStorageKeys.rememberSleepTimer(minutes: 45)
        #expect(AppStorageKeys.sleepTimerRemembered == 45)
    }

    /// Gemerkt wird an der EINEN Stelle, an der eine Uhr-Dauer startet.
    /// Laege es am Menue, merkte der Fahrmodus oder ein spaeterer Aufrufer
    /// nichts, und die Vorgabe waere je nach Weg eine andere.
    @Test("gemerkt wird beim Starten, nicht im Menue")
    func theStartRemembersIt() throws {
        let quelle = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("Sources/ViewModels/PlayerViewModel+SleepTimer.swift"),
            encoding: .utf8)
        let rumpf = try #require(functionBody(of: "func startSleepTimer(minutes: Double) {",
                                             in: quelle))
        #expect(rumpf.contains("rememberSleepTimer"),
                "die Dauer wird beim Starten nicht mehr gemerkt")

        // Und die beiden GRENZEN-Zeitgeber merken nichts: „bis zum Ende des
        // Kapitels" ist keine Dauer und bedeutet bei jedem Stueck etwas
        // anderes.
        for grenze in ["func startSleepTimerUntilChapterEnd() {",
                       "func startSleepTimerUntilTrackEnd() {"] {
            let anderer = try #require(functionBody(of: grenze, in: quelle))
            #expect(!anderer.contains("rememberSleepTimer"),
                    "\(grenze) merkt sich eine Dauer, die es nicht ist")
        }
    }
}
