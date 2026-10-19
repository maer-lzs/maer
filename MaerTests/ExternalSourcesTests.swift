// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Testing
import Foundation
@testable import Maer

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

    /// Hosts the app contacts outside the page of sources, each with its
    /// reason; the README names them beside the page.
    private static let outsideThePage: [String: String] = [
        "api.pocketcasts.com": "the import from Pocket Casts, only when the person starts it",
        "refresh.pocketcasts.com": "the import from Pocket Casts, only when the person starts it",
        "cache.pocketcasts.com": "the import from Pocket Casts, only when the person starts it",
    ]

    /// A host given without a scheme, as the literal assigned to a name that
    /// ends in "host" (`static let apiHost = "api.example.org"`).
    nonisolated static func bareHosts(in text: String) -> [String] {
        text.matches(of: #/[A-Za-z_]*[Hh]ost[A-Za-z_]*\s*[:=]\s*"([a-z0-9.\-]+\.[a-z]{2,})"/#).map { String($0.output.1) }
    }

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
        for url in SourceTree.files(under: root) {
            guard url.pathExtension == "swift" else { continue }
            let text = try String(contentsOf: url, encoding: .utf8)
            var rest = Substring(text)
            while let range = rest.range(of: "https://") {
                let after = rest[range.upperBound...]
                let host = after.prefix { $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" }
                if host.contains(".") { hosts.insert(String(host)) }
                rest = after
            }
            hosts.formUnion(Self.bareHosts(in: text))
        }
        return hosts
    }

    /// Jeder fest verdrahtete fremde Host gehoert einer erklaerten Quelle.
    /// Feed-Hosts (Podcast-Anbieter in kuratierten Listen und Fixtures)
    /// gehoeren der Feed-Artwork-/Inhalts-Seite und sind daran erkennbar,
    /// dass sie in DATEN stehen, nicht in Clients — der Zaun nimmt sie
    /// ueber die bekannte Feed-Host-Liste aus.
    @Test("kein Client spricht mit einem Host, den keine Quelle nennt", .needsTheSources)
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
            // Installationsanleitungen der Server-Projekte: Adressen, die der
            // Browser oeffnet, die App ruft sie nie (ServerGuidesTests haelt
            // sie aus jeder Datei heraus, die eine Verbindung oeffnen kann).
            if ServerGuidesTests.projectHosts.contains(host) { continue }
            if Self.outsideThePage[host] != nil { continue }
            unexplained.append(host)
        }
        // The scan sees a host without a scheme, and the named list holds
        // nothing the code does not contact.
        #expect(Self.bareHosts(in: #"static let apiHost = "api.pocketcasts.com" // x"#) == ["api.pocketcasts.com"])
        #expect(Self.bareHosts(in: #"let name = "file.sqlite""#).isEmpty, "a file name is no host")
        let scanned = try scannedHosts()
        let ghosts = Self.outsideThePage.keys.filter { !scanned.contains($0) }.sorted()
        #expect(ghosts.isEmpty, "named outside the page but contacted nowhere: \(ghosts)")
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

    /// Die Sammel-Aktion fasst nur an, was die Seite auch ZEIGT. Ohne
    /// eigenen Schluessel traegt die PodcastIndex-Zeile keinen Schalter
    /// (sie sagt stattdessen, dass ohne Schluessel nicht gefragt wird), und
    /// ein AUS, das niemand sehen kann, faellt der Person erst Wochen
    /// spaeter auf die Fuesse, wenn sie einen Schluessel eintraegt.
    @Test("ohne Schluessel bleibt PodcastIndex aus der Sammel-Abschaltung heraus")
    func theCollectiveActionSkipsASourceWithoutAnOperableSwitch() throws {
        let ohne = ExternalSources.switchable(podcastIndexConfigured: false)
        let mit = ExternalSources.switchable(podcastIndexConfigured: true)
        #expect(mit.count == ExternalSources.all.count, "mit Schluessel gehoert jede Quelle dazu")
        #expect(ohne.count == ExternalSources.all.count - 1, "ohne Schluessel ist es genau eine weniger")
        #expect(!ohne.contains { $0.key == "podcastIndex" })
        #expect(mit.contains { $0.key == "podcastIndex" })

        // Und am Speicher gemessen, nicht nur an der Liste: der Schluessel
        // der uebersprungenen Quelle wird NICHT geschrieben.
        let suite = "sammel-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let podcastIndex = try #require(ExternalSources.all.first { $0.key == "podcastIndex" })
        ExternalSources.disableAll(defaults: defaults, podcastIndexConfigured: false)
        #expect(defaults.object(forKey: podcastIndex.storageKey) == nil,
                "die Sammel-Aktion hat einen unsichtbaren Schalter umgelegt")
        for source in ExternalSources.all where source.key != "podcastIndex" {
            #expect(defaults.bool(forKey: source.storageKey) == false,
                    "\(source.key) wurde nicht abgeschaltet")
        }

        ExternalSources.disableAll(defaults: defaults, podcastIndexConfigured: true)
        #expect(defaults.bool(forKey: podcastIndex.storageKey) == false,
                "mit Schluessel gehoert PodcastIndex sehr wohl dazu")
    }

    /// Das tragende Prinzip als Test: eine abgeschaltete Quelle betrifft
    /// nur NEUE Abfragen, nie den Bestand. Am Speicher gemessen: die
    /// Sammel-Aktion (die haerteste Form des Abschaltens) schreibt
    /// AUSSCHLIESSLICH Schluessel der Aufzaehlung — Favoriten, Abos,
    /// Hoerstand und jede andere fremde Ablage bleiben byte-gleich.
    ///
    /// Die Tatsache „traegt dieser Bau einen PodcastIndex-Schluessel" ist hier
    /// ein EINGANG, kein Wert, den der Fall selbst liest. Liest ein Zeuge sie
    /// selbst, misst er nur die Richtung, die auf seiner Maschine zufaellig
    /// gilt: mit Schluessel wandert jede Quelle und er ist gruen, ohne
    /// Schluessel ueberspringt die Regel PodcastIndex und derselbe Fall wird
    /// rot, bei gleichem Quelltext. Die Zusage gilt in BEIDEN Richtungen,
    /// also faehrt der Fall beide.
    @Test("Quellen abschalten laesst jeden fremden Schluessel unberuehrt",
          arguments: [false, true])
    func disablingSourcesTouchesOnlySourceKeys(podcastIndexConfigured: Bool) throws {
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

        ExternalSources.disableAll(defaults: defaults,
                                   podcastIndexConfigured: podcastIndexConfigured)

        var nachher = defaults.persistentDomain(forName: suite) ?? [:]
        let quellenSchluessel = Set(ExternalSources.all.map(\.storageKey))
        for key in quellenSchluessel { nachher.removeValue(forKey: key) }
        #expect(Set(nachher.keys) == Set(vorher.keys),
                "die Sammel-Aktion hat fremde Schluessel angefasst: \(Set(nachher.keys).symmetricDifference(Set(vorher.keys)).sorted())")
        // Abgeschaltet ist, was die Seite auch zeigt: die uebersprungene Quelle
        // bleibt unberuehrt, und genau das haelt der Fall daneben fest.
        for source in ExternalSources.switchable(podcastIndexConfigured: podcastIndexConfigured) {
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
