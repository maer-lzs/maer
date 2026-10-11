// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// Der Gehoert-Verlauf vom Geraet (Build 47): aeltere Eintraege ohne Titel
/// und Sendung, drei Eintraege „vor 56 Jahren“. Ein Titel, der beim
/// Schreiben fehlte, kommt nach, ohne neues Hoeren; kein Datum vor 2000.
@MainActor
struct ListenHistoryHealTests {
    private let real = 1_753_180_608_000.0

    @Test("Ein Zeitpunkt in Sekunden wird zu Millisekunden, eine Dauer nimmt den Zeitpunkt des Hoerstands, ein echter bleibt")
    func theDatesHeal() {
        #expect(PodcastListenLog.healedPlayedAt(current: 1_753_180_608, stored: nil) == real,
                "a moment in seconds is the same moment in milliseconds")
        #expect(PodcastListenLog.healedPlayedAt(current: 3600, stored: [3600, real, 3600]) == real)
        #expect(PodcastListenLog.healedPlayedAt(current: 50_000_000, stored: [10, real]) == real,
                "a value that is neither seconds nor a date takes the stand's moment")
        #expect(PodcastListenLog.healedPlayedAt(current: 50_000_000, stored: nil) == nil)
        #expect(PodcastListenLog.healedPlayedAt(current: real, stored: nil) == nil, "a true moment stays")
        #expect(PodcastListenLog.healedPlayedAt(current: 3600, stored: [10, 99]) == nil,
                "a stand whose own moment is no date is not copied")
    }

    @Test("Kein Datum vor 2000 wird gezeigt")
    func noDateBefore2000IsShown() {
        func entry(_ at: Double) -> PodcastListenLog.Entry {
            .init(guid: "g", episodeTitle: "E", showTitle: "S", feedURL: "", duration: 60,
                  playedAt: at, unplayedAt: nil, synthesizedAt: false)
        }
        #expect(PodcastListenLog.shownDate(entry(3600)) == nil)
        #expect(PodcastListenLog.shownDate(entry(1_753_180_608)) == nil, "seconds read as milliseconds is 1970")
        #expect(PodcastListenLog.shownDate(entry(real)) == Date(timeIntervalSince1970: real / 1000))
    }

    @Test("Ein Titel, der beim Schreiben fehlte, kommt mit der naechsten Notiz desselben Stands, ohne neues Hoeren")
    func aMissingTitleArrivesWithoutANewListen() {
        let log = PodcastListenLog.shared
        log._resetForTest()
        defer { log._resetForTest() }
        let guid = "rss:heal:\(UUID().uuidString)"
        // The reconcile wrote it while the episode was not in the stock.
        log.noteIfPlayed(guid: guid, duration: 600, episodeTitle: "", showTitle: "", feedURL: "",
                         written: [600, real])
        #expect(log.entries[guid]?.episodeTitle == "", "the entry stands without a title, else the case measures nothing")
        // The same stand again, now with the episode known: not newer.
        log.noteIfPlayed(guid: guid, duration: 600, episodeTitle: "Folge", showTitle: "Sendung",
                         feedURL: "https://feed.example/x", written: [600, real])
        #expect(log.entries[guid]?.episodeTitle == "Folge")
        #expect(log.entries[guid]?.showTitle == "Sendung")
        #expect(log.entries[guid]?.playedAt == real, "the moment did not move: no new listen was booked")
    }

    @Test("Der Verlauf ergaenzt beim Lesen, was heute aufloesbar ist; was nicht aufloesbar ist, bleibt leer und wird benannt")
    func theHistoryFillsWhatResolves() throws {
        let log = PodcastListenLog.shared
        log._resetForTest()
        defer { log._resetForTest() }
        let known = "rss:heal:\(UUID().uuidString)"
        let gone = "rss:heal:\(UUID().uuidString)"
        for guid in [known, gone] {
            log.noteIfPlayed(guid: guid, duration: 600, episodeTitle: "", showTitle: "", feedURL: "",
                             written: [600, real])
        }
        let rows = log.history { guid in guid == known ? ("Folge", "Sendung", "https://feed.example/x") : nil }
        #expect(rows.first { $0.guid == known }?.episodeTitle == "Folge")
        #expect(rows.first { $0.guid == known }?.showTitle == "Sendung")
        #expect(rows.first { $0.guid == gone }?.episodeTitle == "", "nothing is invented for what does not resolve")
    }

    @Test("Die Zeile zeigt fuer einen fehlenden Titel einen Namen, laesst eine fehlende Sendung und ein falsches Datum weg", .needsTheSources)
    func theRowNamesWhatIsMissing() throws {
        let view = SyncContractFenceTests.stripped(try String(
            contentsOf: SourceTree.root.appendingPathComponent("Sources/Views/Podcasts/PodcastHistoryView.swift"), encoding: .utf8))
        let row = try #require(functionBody(of: "private func rowContent(", in: view))
        #expect(row.contains("PodcastListenLog.shownDate(entry)"))
        #expect(row.contains("subtitle: entry.showTitle"), "the show is not the second line")
        #expect(!row.contains("Date(timeIntervalSince1970: entry.playedAt"), "no date is drawn past the rule")
        // The row itself is the one row of both histories.
        let shared = SyncContractFenceTests.stripped(try String(
            contentsOf: SourceTree.root.appendingPathComponent("Sources/Views/HistoryRow.swift"), encoding: .utf8))
        #expect(shared.contains("String(localized: \"Title unknown\")"))
        #expect(shared.contains("Self.secondLine(subtitle: subtitle"), "the second line is built beside the one rule")
        #expect(!shared.contains("HStack"), "the second line stands as columns again")
    }

    /// The page and its tile are called "Hörverlauf" in German, the word the
    /// owner chose; the empty page says it with the same word.
    @Test("deutsch heisst der Verlauf Hörverlauf, auf der Kachel und auf der leeren Seite", .needsTheSources)
    func theGermanNameIsHoerverlauf() throws {
        let data = try Data(contentsOf: SourceTree.root.appendingPathComponent("Sources/Localizable.xcstrings"))
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let strings = try #require(json["strings"] as? [String: [String: Any]])
        func german(_ key: String) -> String? {
            ((strings[key]?["localizations"] as? [String: Any])?["de"] as? [String: Any])
                .flatMap { $0["stringUnit"] as? [String: Any] }?["value"] as? String
        }
        #expect(german("Listening History") == "Hörverlauf")
        #expect(german("No listening history yet") == "Noch kein Hörverlauf")
        let old = strings.keys.filter { german($0)?.contains("Gehört-Verlauf") == true }
        #expect(old.isEmpty, "the old name still stands: \(old.sorted())")
    }

    /// The second line is one text: who, then how long ago. At a large size
    /// it wraps as one line instead of two columns side by side.
    @Test("die zweite Zeile ist ein Text: wer, dann wie lange her; fehlt eins, steht das andere allein")
    func theSecondLineIsOneText() {
        #expect(HistoryRow.secondLine(subtitle: "Seed Artist", when: "11 minutes ago") == "Seed Artist · 11 minutes ago")
        #expect(HistoryRow.secondLine(subtitle: "", when: "last month") == "last month")
        #expect(HistoryRow.secondLine(subtitle: "Ada Author", when: nil) == "Ada Author")
        #expect(HistoryRow.secondLine(subtitle: "", when: nil) == "")
    }
}
#endif
