// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Testing
import Foundation
@testable import Maer

/// The sources page is only true if it is COMPLETE. The fence
/// holds the enumeration against the host scan of the own network code:
/// if a client talks to a host that no source names, the
/// page has become a lie.
struct ExternalSourcesTests {

    /// The hosts of the own infrastructure and of the content. They explicitly
    /// do NOT belong on the sources page: own servers are no
    /// foreign source, and feed/stream hosts are the CONTENT the
    /// user subscribed to, not a service the app chooses.
    private static let ownedOrContent: Set<String> = [
        "maer.fm", "gpodder.maer.fm",        // own gpodder service
        "api.jellyfin.org",                   // Jellyfin docs link, own server
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

    /// Example and fixture hosts: placeholders in comments and seeds,
    /// never a real contact. Recognized by pattern instead of kept one by one.
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

    /// Every hard-wired foreign host belongs to a declared source.
    /// Feed hosts (podcast providers in curated lists and fixtures)
    /// belong to the feed artwork/content page and are recognizable by
    /// standing in DATA, not in clients. The fence excludes them
    /// through the known feed host list.
    @Test("no client talks to a host that no source names", .needsTheSources)
    func everyHardwiredHostBelongsToASource() throws {
        let declared = Set(ExternalSources.all.flatMap(\.hosts))
        // Feed and station hosts: content, no service. Recognized by the
        // patterns of the curated lists.
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
            // Installation guides of the server projects: addresses the
            // browser opens, the app never calls them (ServerGuidesTests keeps
            // them out of every file that can open a connection).
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

    /// The enumeration itself: unique keys, unique
    /// storage keys, every group filled, and the four measured
    /// catalog sources really stand there as catalogs.
    @Test("the enumeration is unambiguous and carries the measured structure")
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
        // Every source says what then applies, in the TWO-PART form: what
        // stops plus what stays. The stays part stands verbatim in the
        // line, so the twelfth source does not forget the form and the
        // two fields do not drift apart.
        for source in ExternalSources.all {
            #expect(!source.effectLine.isEmpty, "\(source.key) sagt nicht, was dann gilt")
            #expect(!source.staysLine.isEmpty, "\(source.key) sagt nicht, was bleibt")
            #expect(source.effectLine.contains(source.staysLine),
                    "\(source.key): der Bleibt-Teil steht nicht in der Wirkungszeile")
        }
    }

    /// Existing choices survive: sources that have a switch today
    /// keep their KEY. A renamed key would silently reset the
    /// stored decision of every user.
    @Test("existing switches keep their keys")
    func existingSwitchesKeepTheirKeys() {
        let erwartet: [String: String] = [
            "librivox": "librivoxRowsEnabled",
            "internetArchive": "archivePopularEnabled",
            "jamendo": "jamendoRowEnabled",
            "appleCatalog": "appleCatalogEnabled",
            "wikimedia": "radioLogoChainEnabled",
            "musicBrainz": "musicArtistImagesOnline",
            "lrclib": "musicLyricsOnlineLookup",
            // The radio AREA switch has always answered exactly
            // the sources question (it gated the catalog fetches) and is
            // reused; a fresh key would have been a second
            // switch for the same service.
            "radioBrowser": "radioEnabled",
        ]
        for (key, storage) in erwartet {
            #expect(ExternalSources.source(key: key)?.storageKey == storage,
                    "\(key) hat seinen Speicher-Schluessel verloren — jede Nutzer-Wahl waere zurueckgesetzt")
        }
    }

    /// The bulk action only touches what the page also SHOWS. Without an
    /// own key the PodcastIndex row carries no switch
    /// (it says instead that without a key nothing is asked), and
    /// an OFF that nobody can see comes back to bite the person only weeks
    /// later, when they enter a key.
    @Test("without a key PodcastIndex stays out of the bulk switch-off")
    func theCollectiveActionSkipsASourceWithoutAnOperableSwitch() throws {
        let ohne = ExternalSources.switchable(podcastIndexConfigured: false)
        let mit = ExternalSources.switchable(podcastIndexConfigured: true)
        #expect(mit.count == ExternalSources.all.count, "mit Schluessel gehoert jede Quelle dazu")
        #expect(ohne.count == ExternalSources.all.count - 1, "ohne Schluessel ist es genau eine weniger")
        #expect(!ohne.contains { $0.key == "podcastIndex" })
        #expect(mit.contains { $0.key == "podcastIndex" })

        // And measured at the store, not only at the list: the key
        // of the skipped source is NOT written.
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

    /// The load-bearing principle as a test: a switched-off source affects
    /// only NEW queries, never the stock. Measured at the store: the
    /// bulk action (the hardest form of switching off) writes
    /// EXCLUSIVELY keys of the enumeration. Favorites, subscriptions,
    /// listening state and every other foreign store stay byte-identical.
    ///
    /// The fact „traegt dieser Bau einen PodcastIndex-Schluessel" is here
    /// an INPUT, not a value the case reads itself. If a witness reads it
    /// itself, it only measures the direction that happens to hold on its machine:
    /// with a key every source moves and it is green, without a
    /// key the rule skips PodcastIndex and the same case turns
    /// red, with the same source text. The promise holds in BOTH directions,
    /// so the case runs both.
    @Test("switching sources off leaves every foreign key untouched",
          arguments: [false, true])
    func disablingSourcesTouchesOnlySourceKeys(podcastIndexConfigured: Bool) throws {
        let suite = "bestand-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }

        // Lay out the stock: the classes from the decision (station objects,
        // subscriptions, listening state) as stand-in values.
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
        // What is switched off is what the page also shows: the skipped source
        // stays untouched, and exactly that is what the neighboring case pins down.
        for source in ExternalSources.switchable(podcastIndexConfigured: podcastIndexConfigured) {
            #expect(!ExternalSources.isAllowed(source, defaults: defaults))
        }
        // And no source key lies in user ownership: the enumeration
        // must never collide with a stock family.
        for key in quellenSchluessel {
            #expect(!key.hasPrefix("progress:") && !key.hasPrefix("listenLog:")
                    && key != "radioFavorites")
        }
    }
}
