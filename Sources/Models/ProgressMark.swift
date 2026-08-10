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
    ///
    /// **Nicht direkt aufrufen, wenn es die Stelle schon gibt** — dafür ist
    /// `advancing` da. Diese Form baut NEU und verliert dabei, was sie nicht
    /// weiß.
    static func entry(position: Double, duration: Double, nowMs: Double) -> [Double] {
        duration > 0 ? [position, nowMs, duration] : [position, nowMs]
    }

    /// **Fortschreiben statt neu bauen** (Befund ee4fca6).
    ///
    /// Ein eingehender Eintrag ohne bekannte Dauer darf einen VORHANDENEN
    /// Bezugspunkt nicht löschen — er weiß es nicht besser, er weiß es gar
    /// nicht. Genau das ist passiert: Der gpodder-Abgleich rief `entry` mit
    /// `a.total ?? 0` auf, schrieb bei jüngerem Zeitstempel eine
    /// Zwei-Werte-Marke über eine gute Drei-Werte-Marke, und weil der Server
    /// Zeitstempel auf ganze Sekunden rundet, gewann dabei sogar das eigene
    /// Echo. Ohne Abspielen, ohne Geste, im Takt der Synchronisierung.
    ///
    /// Dieselbe Klasse wie die Feldklassen beim Show-Merge: **Wissen, das nur
    /// eine Seite hat, darf nicht daran sterben, dass die andere gewinnt.**
    /// Deshalb steht es hier und nicht an den Aufrufstellen — dann kann auch
    /// keine künftige den Bezugspunkt mehr verlieren.
    static func advancing(_ existing: [Double]?,
                          position: Double,
                          duration: Double,
                          nowMs: Double) -> [Double] {
        let known = duration > 0 ? duration : (existing.flatMap { markedDuration($0) } ?? 0)
        return entry(position: position, duration: known, nowMs: nowMs)
    }

    /// **Nachtragen** (Befund afdcc57): dem vorhandenen Eintrag NUR den
    /// fehlenden Bezugspunkt ergänzen — Position und Zeitstempel bleiben
    /// unangetastet. Kein Merge, keine Übernahme.
    ///
    /// `nil` heißt „nichts zu tun": Der Eintrag hat schon einen, oder die
    /// Gegenseite kennt keine Dauer. Und es entsteht NIE ein Eintrag aus dem
    /// Nichts — eine Heilung, die Gelöschtes zurückholt, wäre die Klasse, die
    /// beim Abo-Abgleich die Massenlösch-Wache abfängt.
    static func supplementing(_ existing: [Double], duration: Double) -> [Double]? {
        guard duration > 0, existing.count >= 2, markedDuration(existing) == nil else { return nil }
        return [existing[0], existing[1], duration]
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
