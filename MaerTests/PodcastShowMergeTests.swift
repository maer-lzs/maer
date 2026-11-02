// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// Die quellenübergreifende Sendungsliste stand fünfmal im Baum, von Hand
/// kopiert, und die Kopien waren NICHT gleich: zwei fragten den ABS-Quellen-
/// schalter, drei nicht. Drei von ihnen behaupteten im eigenen Kommentar,
/// Spiegel der anderen zu sein.
///
/// Dieser Fall hält zwei Dinge fest: was „einmal" bedeutet (am Verhalten der
/// puren Regel) und dass es keine sechste handgeschriebene Fassung mehr gibt
/// (am Quelltext, mit Bestand und Grund je Eintrag).
struct PodcastShowMergeTests {
    private func show(_ id: String, feed: String) -> PodcastShow {
        PodcastShow(id: id, title: id, author: nil, artworkURL: nil,
                    description: nil, feedURL: feed, episodes: [])
    }

    private func sourceText(_ relative: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(relative), encoding: .utf8)
    }

    // MARK: - Die pure Regel

    @Test("Dieselbe Sendung aus beiden Quellen steht einmal, und die ABS-Seite gewinnt")
    func duplicateKeepsTheServerSide() {
        let merged = PodcastShowMerge.merge(
            abs: [show("abs", feed: "https://example.org/feed.xml")],
            rss: [show("rss", feed: "https://example.org/feed.xml")])
        #expect(merged.map(\.id) == ["abs"])
    }

    /// Der Vergleich läuft über die NORMALISIERTE Adresse. Zwei Schreib-
    /// weisen desselben Feeds sind dieselbe Sendung, sonst stünde sie
    /// doppelt — genau der Fall, für den es die Regel gibt.
    @Test("Zwei Schreibweisen derselben Adresse sind eine Sendung")
    func spellingDoesNotSplitAShow() {
        // Zwei Adressen, die sich in Schema, www, Groß-/Kleinschreibung,
        // Schrägstrich und Zähl-Parameter unterscheiden und denselben Feed
        // meinen. Wären sie gleich geschrieben, prüfte der Fall nichts.
        let a = "https://www.Example.org/feed.xml/"
        let b = "http://example.org/feed.xml?utm_source=irgendwas"
        #expect(a != b)
        let merged = PodcastShowMerge.merge(abs: [show("abs", feed: a)],
                                            rss: [show("rss", feed: b)])
        #expect(merged.map(\.id) == ["abs"],
                "verschieden geschriebene Adressen desselben Feeds wurden zu zwei Sendungen")
    }

    @Test("Eine Sendung nur einer Quelle bleibt, und die Reihenfolge bleibt auch")
    func orderIsKept() {
        let merged = PodcastShowMerge.merge(
            abs: [show("a1", feed: "https://a.org/1"), show("a2", feed: "https://a.org/2")],
            rss: [show("r1", feed: "https://r.org/1"), show("r2", feed: "https://r.org/2")])
        #expect(merged.map(\.id) == ["a1", "a2", "r1", "r2"],
                "die Liste ordnet sich unter dem Nutzer um")
    }

    @Test("Leere Quellen ergeben die jeweils andere")
    func emptySideChangesNothing() {
        let one = [show("r1", feed: "https://r.org/1")]
        #expect(PodcastShowMerge.merge(abs: [], rss: one).map(\.id) == ["r1"])
        #expect(PodcastShowMerge.merge(abs: one, rss: []).map(\.id) == ["r1"])
        #expect(PodcastShowMerge.merge(abs: [], rss: []).isEmpty)
    }

    @Test("Die Abo-Frage findet den Feed unabhaengig von der Schreibweise")
    func containsNormalises() {
        let shows = [show("s", feed: "https://example.org/feed.xml")]
        #expect(PodcastShowMerge.contains(feedURL: "https://example.org/feed.xml", in: shows))
        #expect(!PodcastShowMerge.contains(feedURL: "https://other.org/feed.xml", in: shows))
    }

    // MARK: - Die Saat der Empfehlungen (Produkt-Entscheid 08.09.2026)

    @Test("Eine Sendung aus beiden Toepfen steht in der Saat einmal")
    func seedFoldsTheTwins() {
        let groups = PodcastShowMerge.foldByFeed([
            show("abs", feed: "https://example.org/feed.xml"),
            show("rss", feed: "https://example.org/feed.xml"),
            show("nur-rss", feed: "https://other.org/feed.xml"),
        ])
        #expect(groups.count == 2, "die Zwillinge wurden nicht gefaltet")
        #expect(groups.map { $0.first?.id } == ["abs", "nur-rss"],
                "der Sieger ist nicht die Kopie, die auch die Anzeige behaelt")
        #expect(groups[0].map(\.id) == ["abs", "rss"],
                "die Gruppe muss ihre Zwillinge behalten, sonst geht Hoerzeit verloren")
    }

    /// Ohne diesen Fall koennte die Faltung eine Sendung SCHWAECHER machen:
    /// die Hoerzeit steht je Sendungs-Kennung, und die zwei Kopien haben
    /// zwei Kennungen. Faellt die eine weg, faellt ihre Zeit mit.
    @Test("Falten kostet eine Sendung ihre Hoerzeit nicht")
    func foldingCostsNoListeningTime() {
        let groups = PodcastShowMerge.foldByFeed([
            show("abs", feed: "https://example.org/feed.xml"),
            show("rss", feed: "https://example.org/feed.xml"),
        ])
        // Die ganze Geschichte liegt unter der Kennung, die NICHT ueberlebt.
        let lifted = PodcastShowMerge.liftingTwins(["rss": 900], groups: groups)
        #expect(lifted["abs"] == 900, "die Zeit des Zwillings ging verloren")
    }

    /// MAX und nicht Summe: dieselbe Folge kann unter beiden Schreibweisen
    /// eine gespeicherte Stelle tragen. Summieren zaehlte ein Hoeren doppelt
    /// und waere genau der Fehler, gegen den die Faltung gebaut ist.
    @Test("Zwei Kopien mit Zeit ergeben nicht die Summe")
    func twinsDoNotAddUp() {
        let groups = PodcastShowMerge.foldByFeed([
            show("abs", feed: "https://example.org/feed.xml"),
            show("rss", feed: "https://example.org/feed.xml"),
        ])
        let lifted = PodcastShowMerge.liftingTwins(["abs": 600, "rss": 900], groups: groups)
        #expect(lifted["abs"] == 900, "die Zwillingszeiten wurden addiert statt verglichen")
    }

    @Test("Eine Sendung aus nur einer Quelle behaelt ihre Zeit unveraendert")
    func singleSourceIsUntouched() {
        let groups = PodcastShowMerge.foldByFeed([show("nur-rss", feed: "https://other.org/feed.xml")])
        #expect(PodcastShowMerge.liftingTwins(["nur-rss": 120], groups: groups)["nur-rss"] == 120)
        // Ohne Zeit entsteht auch keine.
        #expect(PodcastShowMerge.liftingTwins([:], groups: groups)["nur-rss"] == nil)
    }

    /// Der Kapsel-Ausschluss der Saat fragt die ADRESSE und nicht die Kopie.
    /// `origin` wird nur lokal gesetzt, ABS setzt es nie, und die Server-
    /// Spiegelung schiebt Kapseln wie alles andere hinueber — der ABS-
    /// Zwilling kommt also OHNE Markierung zurueck. Ein Filter je Kopie
    /// liesse ihn in eine OEFFENTLICHE Katalogsuche laufen (der IDA-Vorfall).
    @Test("Eine gespiegelte Kapsel bleibt auch als ABS-Zwilling draussen")
    func mirroredCapsuleStaysOutThroughItsTwin() {
        var capsule = show("rss-kapsel", feed: "https://pinchflat.local/feed.xml")
        capsule.origin = "pinchflat"
        let twin = show("abs-kapsel", feed: "https://pinchflat.local/feed.xml")  // ohne origin
        #expect(PodcastShowMerge.seedGroups(abs: [twin], rss: [capsule]).isEmpty,
                "der unmarkierte Server-Zwilling der Kapsel kam durch")
        // Gegenprobe: dieselbe Sendung OHNE Markierung bleibt drin. Sonst
        // koennte der Fall auch gruen sein, weil die Saat gar nichts durchlaesst.
        var plain = capsule
        plain.origin = nil
        #expect(PodcastShowMerge.seedGroups(abs: [twin], rss: [plain]).count == 1)
    }

    @Test("Die Saat faellt eine Sendung aus beiden Toepfen auf eine zusammen")
    func seedFoldsAcrossPots() {
        let groups = PodcastShowMerge.seedGroups(
            abs: [show("abs", feed: "https://example.org/feed.xml")],
            rss: [show("rss", feed: "https://example.org/feed.xml"),
                  show("nur-rss", feed: "https://other.org/feed.xml")])
        #expect(groups.map { $0.first?.id } == ["abs", "nur-rss"])
    }

    // MARK: - Was wir BESITZEN (die zweite Frage der Tuer)

    @Test("Die Abo-Adressen sind eine Menge, und die Schreibweise faltet mit")
    func normalizedFeedsFoldsSpelling() {
        let feeds = PodcastShowMerge.normalizedFeeds([
            show("a", feed: "https://www.Example.org/feed.xml/"),
            show("b", feed: "http://example.org/feed.xml?utm_source=x"),
            show("c", feed: "https://other.org/feed.xml"),
        ])
        #expect(feeds.count == 2, "zwei Schreibweisen desselben Feeds gelten als zwei Abos")
        #expect(feeds.contains(PodcastIdentity.normalizeFeedURL("https://other.org/feed.xml")))
    }

    /// Sechs Stellen bauten die Vereinigung „was wir besitzen" von Hand,
    /// immer ueber dieselben zwei vollen Listen, immer um sie an
    /// `excludingSubscribed` zu geben. Sie waren sich einig, was Glueck war:
    /// eine Menge, der eine Adresse fehlt, stellt eine Sendung, der jemand
    /// schon folgt, zurueck in seine Empfehlungen.
    @Test("Niemand baut die Besitz-Vereinigung noch selbst", .needsTheSources)
    func nobodyBuildsTheOwnedUnionByHand() throws {
        let allowed = "Sources/ViewModels/PodcastShowSources.swift"
        var offenders: [String] = []
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources")
        for url in SourceTree.files(under: root) where url.pathExtension == "swift" {
            let relative = SourceTree.relativePath(of: url)
            if relative == allowed { continue }
            // Zwischenraeume zusammengeschoben, damit ein Umbruch mitten im
            // Ausdruck den Fund nicht verbirgt.
            let flat = try sourceText(relative)
                .split(separator: "\n", omittingEmptySubsequences: false)
                .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
                .joined(separator: " ")
                .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            if flat.contains(".shows + ABSPodcastProvider.shared.shows") { offenders.append(relative) }
        }
        #expect(offenders.isEmpty, "handgeschriebene Besitz-Vereinigung in: \(offenders)")
    }

    // MARK: - Der Bestand am Quelltext

    /// Die Zwischengröße der handgeschriebenen Fassung. Wer die Liste wieder
    /// selbst zusammensetzt, braucht sie; wer die Regel ruft, nicht.
    @Test("Niemand setzt die quellenuebergreifende Liste noch selbst zusammen", .needsTheSources)
    func nobodyBuildsTheMergeByHand() throws {
        let allowed = ["Sources/Models/PodcastShowMerge.swift"]
        var offenders: [String] = []
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources")
        for url in SourceTree.files(under: root) where url.pathExtension == "swift" {
            let relative = SourceTree.relativePath(of: url)
            if allowed.contains(relative) { continue }
            let text = try sourceText(relative)
            if text.contains("absFeeds") { offenders.append(relative) }
        }
        #expect(offenders.isEmpty,
                "handgeschriebene Fassung der Quellen-Vereinigung in: \(offenders.joined(separator: ", "))")
    }

    /// `activeShows` heißt „nicht archiviert" und weiß nichts vom Quellen-
    /// schalter. Genau in dieser Lücke sind die drei ungetorten Kopien
    /// gelandet. Der Bestand nennt je Leser den Grund, warum er ihn liest.
    @Test("activeShows wird nur an zwei Stellen gelesen, und beide sagen warum", .needsTheSources)
    func activeShowsHasTwoReadersWithReasons() throws {
        let expected: [String: String] = [
            "Sources/ViewModels/PodcastShowSources.swift":
                "das eine Tor: liest activeShows UND fragt den Quellenschalter davor",
            "Sources/Providers/PodcastRecommendationsStore.swift":
                "andere Frage: Saat der Empfehlungen. Faltet seit dem Entscheid vom 08.09.2026 "
                + "ueber PodcastShowMerge.seedGroups, aber OHNE Quellenschalter — „zeig mir diese "
                + "Quelle nicht\" ist nicht „vergiss, was ich dort gehoert habe\"",
        ]
        var found: Set<String> = []
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources")
        for url in SourceTree.files(under: root) where url.pathExtension == "swift" {
            let relative = SourceTree.relativePath(of: url)
            let body = try sourceText(relative)
                .split(separator: "\n", omittingEmptySubsequences: false)
                .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
                .joined(separator: "\n")
            // Die Erklaerung im Anbieter selbst ist die Fassung, nicht ein Leser.
            if body.contains("activeShows"), !body.contains("var activeShows") {
                found.insert(relative)
            }
        }
        #expect(found == Set(expected.keys),
                "neue oder verschwundene Leser von activeShows: \(found.symmetricDifference(Set(expected.keys)).sorted())")
    }
}
#endif
