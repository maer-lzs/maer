// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation

/// Wie „gehört" gespeichert und wieder gelesen wird.
///
/// **Gemessen, nicht vermutet (10.08.):** Bei Sendungen auf Megaphone wird
/// Werbung ZUFÄLLIG je Abruf eingesetzt — Spotifys eigene Dokumentation nennt
/// es „random ad insertion… it may show up or not in any given request". Die
/// gemeldete Dauer ist für diese Klasse also **keine stabile Eigenschaft**.
///
/// Vorher hieß „gehört" lokal: `Position ≥ heutige Dauer − 1`. Wuchs die Dauer
/// zwischen zwei Abrufen um drei Minuten, fiel die Marke, und sechs fertige
/// Folgen zeigten sich wieder als „noch 3 Min." — bei jeder Auffrischung neu.
/// Die Gegenprobe am Server (41 Folgen, 38 exakt auf `total`, keine einzige
/// nahe dem Ende) hat die Abgleich-Vermutung ausgeschlossen: Der Defekt lag
/// in der lokalen RÜCK-Ableitung.
///
/// Deshalb speichert der Eintrag die Dauer mit, die beim Markieren galt:
/// `[Position, Zeitstempel, damalige Dauer]`. „Gehört" heißt dann **„die
/// Position entspricht der Dauer, die damals galt"** — unabhängig davon, wie
/// viel Werbung heute drinsteckt. Ältere Einträge (`count == 2`) verhalten
/// sich unverändert, und **nach außen** geht weiterhin die echte Endposition:
/// gpodder und Audiobookshelf erwarten `position = total`, und das ist auch
/// richtig so.
nonisolated enum ProgressMark {
    /// Position, die „gehört" bedeutet, wenn die Folge keine Dauer meldet.
    /// 30 Tage — jenseits jeder echten Folge und klein genug für die
    /// Int-Umrechnung beim gpodder-Push.
    static let playedSentinel: Double = 2_592_000

    /// Der zu speichernde Eintrag. Die Dauer kommt nur mit, wenn sie bekannt
    /// ist — ein erfundener Wert wäre schlimmer als keiner.
    static func entry(position: Double, duration: Double, nowMs: Double) -> [Double] {
        duration > 0 ? [position, nowMs, duration] : [position, nowMs]
    }

    /// Die Dauer, die beim Schreiben galt — falls der Eintrag sie trägt.
    static func markedDuration(_ stored: [Double]) -> Double? {
        stored.count >= 3 && stored[2] > 0 ? stored[2] : nil
    }

    /// Gilt der Eintrag als gehört?
    ///
    /// Reihenfolge mit Absicht: Wächterwert zuerst (er braucht keine Dauer),
    /// dann die MITGESPEICHERTE Dauer, und erst zuletzt die heutige — die
    /// letzte Stufe ist der alte Weg und gilt nur noch für Einträge ohne
    /// dritten Wert.
    static func isPlayed(stored: [Double], currentDuration: Double) -> Bool {
        guard let position = stored.first else { return false }
        if position >= playedSentinel { return true }
        if let marked = markedDuration(stored) { return position >= marked - 1 }
        guard currentDuration > 0 else { return false }
        return position >= currentDuration - 1
    }
}
