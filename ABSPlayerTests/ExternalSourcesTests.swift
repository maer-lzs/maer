// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Testing
import Foundation
@testable import ABSPlayer

/// Die Quellen-Seite ist nur wahr, wenn sie VOLLSTAENDIG ist. Der Zaun
/// haelt die Aufzaehlung gegen den Host-Scan des eigenen Netz-Codes:
/// spricht ein Client mit einem Host, den keine Quelle nennt, ist die
/// Seite eine Luege geworden.
struct ExternalSourcesTests {

    /// Die Hosts der eigenen Infrastruktur und der Inhalte. Sie gehoeren
    /// ausdruecklich NICHT auf die Quellen-Seite: eigene Server sind keine
    /// fremde Quelle, und Feed-/Stream-Hosts sind der INHALT, den der
    /// Nutzer abonniert hat, nicht ein Dienst, den die App waehlt.
    private static let ownedOrContent: Set<String> = [
        "maer.fm", "gpodder.maer.fm",        // eigener gpodder-Dienst
        "api.jellyfin.org",                   // Jellyfin-Doku-Verweis, eigener Server
        "host", "seed.invalid",
    ]

    /// Beispiel- und Fixture-Hosts: Platzhalter in Kommentaren und Seeds,
    /// nie ein echter Kontakt. Am Muster erkannt statt einzeln gepflegt.
    private static func isExampleHost(_ host: String) -> Bool {
        host.contains("example") || host.hasSuffix(".invalid") || host.hasSuffix(".example")
    }

    private func scannedHosts() throws -> Set<String> {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources")
        var hosts: Set<String> = []
        let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)
        while let url = walker?.nextObject() as? URL {
            guard url.pathExtension == "swift" else { continue }
            let text = try String(contentsOf: url, encoding: .utf8)
            var rest = Substring(text)
            while let range = rest.range(of: "https://") {
                let after = rest[range.upperBound...]
                let host = after.prefix { $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" }
                if host.contains(".") { hosts.insert(String(host)) }
                rest = after
            }
        }
        return hosts
    }

    /// Jeder fest verdrahtete fremde Host gehoert einer erklaerten Quelle.
    /// Feed-Hosts (Podcast-Anbieter in kuratierten Listen und Fixtures)
    /// gehoeren der Feed-Artwork-/Inhalts-Seite und sind daran erkennbar,
    /// dass sie in DATEN stehen, nicht in Clients — der Zaun nimmt sie
    /// ueber die bekannte Feed-Host-Liste aus.
    @Test("kein Client spricht mit einem Host, den keine Quelle nennt")
    func everyHardwiredHostBelongsToASource() throws {
        let declared = Set(ExternalSources.all.flatMap(\.hosts))
        // Feed- und Sender-Hosts: Inhalt, kein Dienst. Erkannt an den
        // Mustern der kuratierten Listen.
        let contentPatterns = ["feeds.", "rss.", "podcast", "audiothek", ".ard", "srf.ch",
                               "wdr", "swr", "mdr", "ndr", "rbb", "br.de", "deutschlandfunk",
                               "hoerspiel", "hoer-talk", "drabblecast", "escapepod",
                               "castofwonders", "clarkesworld", "pseudopod", "libsyn", "acast",
                               "megaphone", "art19", "feedburner", "omny", "podigee",
                               "julep", "buzzsprout", "anchor", "soundcloud", "simplecast",
                               "captivate", "podbean", "transistor", "fyyd", "zdf",
                               "radiobremen", "1live", "fritz", "detektor", "egofm",
                               "byte.fm", "laut.fm", "radioeins"]
        var unexplained: [String] = []
        for host in try scannedHosts() {
            if declared.contains(host) { continue }
            if Self.ownedOrContent.contains(host) { continue }
            if Self.isExampleHost(host) { continue }
            if contentPatterns.contains(where: { host.contains($0) }) { continue }
            unexplained.append(host)
        }
        #expect(unexplained.isEmpty,
                "Hosts ohne erklaerte Quelle: \(unexplained.sorted()). Entweder gehoeren sie einer neuen Quelle auf der Seite, oder der Inhalts-Ausnahmeliste hier — beides ist eine benannte Entscheidung.")
    }

    /// Die Aufzaehlung selbst: eindeutige Schluessel, eindeutige
    /// Speicher-Schluessel, jede Gruppe besetzt, und die vier gemessenen
    /// Katalog-Quellen stehen wirklich als Kataloge da.
    @Test("die Aufzaehlung ist eindeutig und traegt die gemessene Gliederung")
    func theEnumerationIsSound() {
        let keys = ExternalSources.all.map(\.key)
        #expect(Set(keys).count == keys.count, "doppelte Quellen-Schluessel")
        let storage = ExternalSources.all.map(\.storageKey)
        #expect(Set(storage).count == storage.count, "zwei Quellen teilen einen Speicher-Schluessel")
        for group in ExternalSourceGroup.allCases {
            #expect(ExternalSources.all.contains { $0.group == group },
                    "die Gruppe \(group.rawValue) ist leer")
        }
        for key in ["librivox", "gutenberg", "internetArchive", "jamendo"] {
            #expect(ExternalSources.source(key: key)?.group == .catalogs)
        }
        // Jede Quelle sagt, was dann gilt — in der ZWEI-TEILE-Form: was
        // stoppt plus was bleibt. Der Bleibt-Teil steht woertlich in der
        // Zeile, damit die zwoelfte Quelle die Form nicht vergisst und die
        // zwei Felder nicht auseinanderdriften.
        for source in ExternalSources.all {
            #expect(!source.effectLine.isEmpty, "\(source.key) sagt nicht, was dann gilt")
            #expect(!source.staysLine.isEmpty, "\(source.key) sagt nicht, was bleibt")
            #expect(source.effectLine.contains(source.staysLine),
                    "\(source.key): der Bleibt-Teil steht nicht in der Wirkungszeile")
        }
    }

    /// Bestehende Wahlen ueberleben: Quellen, die heute einen Schalter
    /// haben, behalten ihren SCHLUESSEL. Ein umbenannter Schluessel wuerde
    /// die gespeicherte Entscheidung jedes Nutzers still zuruecksetzen.
    @Test("bestehende Schalter behalten ihre Schluessel")
    func existingSwitchesKeepTheirKeys() {
        let erwartet: [String: String] = [
            "librivox": "librivoxRowsEnabled",
            "internetArchive": "archivePopularEnabled",
            "jamendo": "jamendoRowEnabled",
            "appleCatalog": "appleCatalogEnabled",
            "wikimedia": "radioLogoChainEnabled",
            "musicBrainz": "musicArtistImagesOnline",
            "lrclib": "musicLyricsOnlineLookup",
            // Der Radio-BEREICHS-Schalter beantwortete immer schon genau
            // die Quellen-Frage (er torte die Katalog-Abrufe) und wird
            // wiederverwendet; ein frischer Schluessel waere ein zweiter
            // Schalter fuer denselben Dienst gewesen.
            "radioBrowser": "radioEnabled",
        ]
        for (key, storage) in erwartet {
            #expect(ExternalSources.source(key: key)?.storageKey == storage,
                    "\(key) hat seinen Speicher-Schluessel verloren — jede Nutzer-Wahl waere zurueckgesetzt")
        }
    }

    /// Die Migration traegt das alte Master-AUS in die Quellen-Schluessel,
    /// einmal. Ohne sie fragte ein Nutzer, der den Master ausgeschaltet
    /// hatte, still wieder an — das Eine, was der Neubau nie tun darf.
    @Test("Master aus wird einmalig zu Quellen aus, Master an migriert nichts")
    func theMasterOffMigratesOnce() throws {
        let suite = "migration-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }

        // Master war AUS: jede Katalog-Quelle geht aus, Anreicherung bleibt.
        defaults.set(false, forKey: AppStorageKeys.freeCatalogsMasterEnabled)
        ExternalSources.migrateMasterIfNeeded(defaults: defaults)
        for source in ExternalSources.all where source.group == .catalogs {
            #expect(!ExternalSources.isAllowed(source, defaults: defaults),
                    "\(source.key) fragt nach der Migration wieder an")
        }
        #expect(ExternalSources.isAllowed(ExternalSources.lrclib, defaults: defaults),
                "die Migration hat eine Quelle angefasst, die der Master nie regierte")
        // Die EINE master-regierte Reihe aus Feeds statt Quellen: ihre
        // Kacheln holen Artwork von fremden Hosts, sobald sie stehen. Das
        // alte Versprechen war "aus stoppt den Verkehr" — also faellt sie
        // ausdruecklich mit.
        #expect(!AppStorageKeys.boolValue(AppStorageKeys.rowPodcastsRadioPlaysVisible, in: defaults),
                "die Hoerspiel-Reihe stuende nach Master-aus wieder da und holte Artwork")

        // EINMALIG: ein spaeteres Wieder-Einschalten einer Quelle ueberlebt
        // den naechsten Start. Sonst raeumte jeder Start die Wahl wieder ab.
        defaults.set(true, forKey: ExternalSources.jamendo.storageKey)
        ExternalSources.migrateMasterIfNeeded(defaults: defaults)
        #expect(ExternalSources.isAllowed(ExternalSources.jamendo, defaults: defaults),
                "die Migration laeuft mehrfach und raeumt die neue Wahl ab")

        // Master AN (oder nie gesetzt): keine Migration, nichts faellt.
        let suite2 = "migration2-\(UUID().uuidString)"
        let an = try #require(UserDefaults(suiteName: suite2))
        defer { UserDefaults.standard.removePersistentDomain(forName: suite2) }
        ExternalSources.migrateMasterIfNeeded(defaults: an)
        for source in ExternalSources.all {
            #expect(ExternalSources.isAllowed(source, defaults: an))
        }
    }

    /// Das tragende Prinzip als Test: eine abgeschaltete Quelle betrifft
    /// nur NEUE Abfragen, nie den Bestand. Am Speicher gemessen: die
    /// Sammel-Aktion (die haerteste Form des Abschaltens) schreibt
    /// AUSSCHLIESSLICH Schluessel der Aufzaehlung — Favoriten, Abos,
    /// Hoerstand und jede andere fremde Ablage bleiben byte-gleich.
    @Test("Quellen abschalten laesst jeden fremden Schluessel unberuehrt")
    func disablingSourcesTouchesOnlySourceKeys() throws {
        let suite = "bestand-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }

        // Bestand hinlegen: die Klassen aus dem Entscheid (Sender-Objekte,
        // Abos, Hoerstand) als Stellvertreter-Werte.
        defaults.set(["sender-a", "sender-b"], forKey: "radioFavorites")
        defaults.set("hoerstand", forKey: "listenLog:buch1")
        defaults.set(9.5, forKey: "progress:rss:abc")
        defaults.set(true, forKey: "praemie")
        let vorher = defaults.persistentDomain(forName: suite) ?? [:]

        ExternalSources.disableAll(defaults: defaults)

        var nachher = defaults.persistentDomain(forName: suite) ?? [:]
        let quellenSchluessel = Set(ExternalSources.all.map(\.storageKey))
        for key in quellenSchluessel { nachher.removeValue(forKey: key) }
        #expect(Set(nachher.keys) == Set(vorher.keys),
                "die Sammel-Aktion hat fremde Schluessel angefasst: \(Set(nachher.keys).symmetricDifference(Set(vorher.keys)).sorted())")
        for source in ExternalSources.all {
            #expect(!ExternalSources.isAllowed(source, defaults: defaults))
        }
        // Und kein Quellen-Schluessel liegt im Nutzerbesitz: die Aufzaehlung
        // darf nie mit einer Bestands-Familie kollidieren.
        for key in quellenSchluessel {
            #expect(!key.hasPrefix("progress:") && !key.hasPrefix("listenLog:")
                    && key != "radioFavorites")
        }
    }
}
