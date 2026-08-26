// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation

/// Die App stellte sich fremden Servern unter SECHS handgepflegten Kennungen
/// vor. Vier Versionswerte (`Maer/1.0` ganz ohne Adresse, `2.1`, `2.6`,
/// `2.7`) auf sechs Zeichenketten. Und eine davon nannte die private
/// Entwicklungs-Forge, die damit bei jedem Künstlerbild-Abruf an fremde
/// Bilddienste ging.
///
/// Dieselbe Fehlerklasse wie die verstreuten Aktivierungs-Vorgaben: derselbe
/// Wert an N Stellen, und N−1 driften ab. Deshalb steht die Kennung ab jetzt
/// **einmal** hier und leitet die Version aus dem Bundle ab. Beim nächsten
/// Versionssprung zieht sie von selbst mit, statt dass fünf von sechs
/// vergessen werden.
///
/// Die Adresse ist `maer.fm` und nicht die Forge: sie bleibt gültig, wenn die
/// Forge wechselt. MusicBrainz und Radio Browser verlangen ausdrücklich eine
/// identifizierende Kennung mit Kontaktweg. Mit sechs Identitäten ist jede
/// Zuordnung auf ihrer Seite wertlos.
nonisolated enum AppUserAgent {
    /// Die EINE Selbstvorstellung der App gegenüber fremden Servern.
    static let value: String = {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        return "Maer/\(version ?? "0") (+https://maer.fm)"
    }()

    /// Setzt sie auf eine Anfrage. Damit keine Aufrufstelle den Feldnamen
    /// selbst schreibt.
    static func apply(to request: inout URLRequest) {
        request.setValue(value, forHTTPHeaderField: "User-Agent")
    }
}
