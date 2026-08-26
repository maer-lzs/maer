// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation

/// Die abgeleiteten Speicher an EINER Stelle, mit der Grenze IM CODE statt
/// in einer Beschriftung.
///
/// Abgeleitet heißt: aus einer Abfrage entstanden und jederzeit neu holbar.
/// Nichts hier gehört dem Nutzer. Kein Hörstand, keine Playlist, kein
/// Favorit, kein Download. Die Grenze zwischen neu holen und Datenverlust
/// steht deshalb als LISTE da: wer einen Schlüssel hinzufügt, muss ihn hier
/// hinschreiben, und der Zaun hält dagegen, dass Nutzerbesitz hineinrutscht.
///
/// Der Hebel ersetzt den Fingerabdruck NICHT. Er macht die kalte Form von
/// Hand erreichbar, damit ein Zustand, den man sonst einmal in 24 Stunden
/// erwischt, überhaupt prüfbar ist.
nonisolated enum DerivedStores {
    /// Was geräumt wird. Anzeigename und Schlüssel. Der Name reist mit, weil
    /// der Hebel sagen muss, WAS er geleert hat.
    struct Entry: Sendable {
        let label: String
        let key: String
    }

    static let all: [Entry] = [
        Entry(label: "Gutenberg shelves (daily)", key: "catalogGutenbergShelfStock"),
        Entry(label: "Archive runtimes", key: "archiveRuntimeSeconds"),
        Entry(label: "Withdrawn catalog items", key: DeadCatalogItems.storeKey),
    ]

    /// Schlüssel, die dem NUTZER gehören. Sie stehen hier, damit der Zaun sie
    /// gegen `all` halten kann. Eine Liste, die man vergisst zu pflegen,
    /// wäre wertlos, eine, gegen die geprüft wird, nicht.
    static let userOwnedPrefixes = ["localPosition.", "playbackClaim", "userChoices",
                                    "maerPlaylists", "radioFavorites", "listeningStats"]

    /// Räumt und sagt, was geräumt wurde. Gibt die Namen zurück, die wirklich
    /// etwas enthielten. Nichts zu räumen ist eine Antwort, keine leere
    /// Meldung.
    @discardableResult
    static func clear(defaults: UserDefaults = .standard) -> [String] {
        var geleert: [String] = []
        for entry in all where defaults.object(forKey: entry.key) != nil {
            defaults.removeObject(forKey: entry.key)
            geleert.append(entry.label)
        }
        return geleert
    }
}
