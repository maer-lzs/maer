// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation

/// Befund 09.08.: die App stellte sich fremden Servern unter VIER Kennungen
/// vor — `Maer/1.0` (ohne Adresse), `2.1`, `2.6`, `2.7` — und eine davon nannte
/// die PRIVATE Forge (`git.lschroeder.eu`), die damit bei jedem
/// Künstlerbild-Abruf an fremde Bilddienste ging. Das war die einzige Stelle
/// im ausgelieferten Code, die etwas Internes nach außen sendete.
///
/// Dieselbe Fehlerklasse wie die verstreuten Aktivierungs-Vorgaben: derselbe
/// Wert an N Stellen, und N−1 driften ab. Deshalb steht die Kennung ab jetzt
/// **einmal** hier und leitet die Version aus dem Bundle ab — beim nächsten
/// Versionssprung zieht sie von selbst mit, statt dass drei von vier
/// vergessen werden.
///
/// Die Adresse ist `maer.fm` und nicht die Forge: sie bleibt gültig, wenn die
/// Forge wechselt. MusicBrainz und Radio Browser verlangen ausdrücklich eine
/// identifizierende Kennung mit Kontaktweg — mit vier Identitäten ist jede
/// Zuordnung auf ihrer Seite wertlos.
nonisolated enum AppUserAgent {
    /// Die EINE Selbstvorstellung der App gegenüber fremden Servern.
    static let value: String = {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        return "Maer/\(version ?? "0") (+https://maer.fm)"
    }()

    /// Setzt sie auf eine Anfrage — damit keine Aufrufstelle den Feldnamen
    /// selbst schreibt.
    static func apply(to request: inout URLRequest) {
        request.setValue(value, forHTTPHeaderField: "User-Agent")
    }
}
