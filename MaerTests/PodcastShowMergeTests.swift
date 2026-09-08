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

    // MARK: - Der Bestand am Quelltext

    /// Die Zwischengröße der handgeschriebenen Fassung. Wer die Liste wieder
    /// selbst zusammensetzt, braucht sie; wer die Regel ruft, nicht.
    @Test("Niemand setzt die quellenuebergreifende Liste noch selbst zusammen")
    func nobodyBuildsTheMergeByHand() throws {
        let allowed = ["Sources/Models/PodcastShowMerge.swift"]
        var offenders: [String] = []
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources")
        guard let walker = FileManager.default.enumerator(atPath: root.path) else {
            Issue.record("Sources nicht lesbar"); return
        }
        for case let name as String in walker where name.hasSuffix(".swift") {
            let relative = "Sources/" + name
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
    @Test("activeShows wird nur an zwei Stellen gelesen, und beide sagen warum")
    func activeShowsHasTwoReadersWithReasons() throws {
        let expected: [String: String] = [
            "Sources/ViewModels/PodcastShowSources.swift":
                "das eine Tor: liest activeShows UND fragt den Quellenschalter davor",
            "Sources/Providers/PodcastRecommendationsStore.swift":
                "andere Frage: Saat der Empfehlungen, absichtlich ohne gespiegelte Feeds, "
                + "nicht die Anzeige-Liste. Nicht stillschweigend mitgefaltet",
        ]
        var found: Set<String> = []
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources")
        guard let walker = FileManager.default.enumerator(atPath: root.path) else {
            Issue.record("Sources nicht lesbar"); return
        }
        for case let name as String in walker where name.hasSuffix(".swift") {
            let relative = "Sources/" + name
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
