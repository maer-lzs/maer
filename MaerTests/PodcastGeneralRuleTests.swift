// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// Werte fuer alle Sendungen (P8 D5, D6, D1): wer folgt, wer eine eigene
/// Einstellung hat, was eine Aenderung trifft und was sie kostet.
@MainActor
struct PodcastGeneralRuleTests {
    static func source(_ path: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }

    @Test("D5: ohne eigenen Wert folgt die Sendung, und ein Wert gleich dem allgemeinen ist keine eigene Einstellung")
    func whoFollows() {
        #expect(PodcastGeneralRule.effective(stored: nil, general: "latest") == "latest")
        #expect(PodcastGeneralRule.effective(stored: "off", general: "latest") == "off")
        #expect(PodcastGeneralRule.own(stored: ["a": "latest", "b": "all", "c": "off"], general: "all") == ["a", "c"])
    }

    @Test("D6: Alle ueberschreiben nimmt jede eigene, Nur ohne eigene nimmt nur die Kopien des alten Werts")
    func whatAChangeClears() {
        let stored = ["a": "latest", "b": "all"]
        #expect(PodcastGeneralRule.cleared(stored: stored, old: "all", answer: .overwriteAll) == ["a", "b"])
        #expect(PodcastGeneralRule.cleared(stored: stored, old: "all", answer: .keepOwn) == ["b"],
                "a keeps its own; b stored the old value and follows the new one")
    }

    @Test("Die Kuerzung trifft nur folgende Sendungen und nennt die Zahl der Folgen je Antwort")
    func onlyFollowersLoseEpisodes() {
        // Old limit unlimited, new 10. a stored the old value (follows),
        // b keeps 50 of its own, c never chose.
        let counts = ["a": 30, "b": 60, "c": 15]
        let stored = ["a": "0", "b": "50"]
        #expect(PodcastGeneralRule.removedEpisodes(episodeCounts: counts, stored: stored, old: "0",
                                                   newLimit: 10, answer: .keepOwn) == 25,
                "a loses 20, c loses 5, b keeps its own 50")
        #expect(PodcastGeneralRule.removedEpisodes(episodeCounts: counts, stored: stored, old: "0",
                                                   newLimit: 10, answer: .overwriteAll) == 75)
        #expect(PodcastGeneralRule.removedEpisodes(episodeCounts: counts, stored: stored, old: "10",
                                                   newLimit: 0, answer: .overwriteAll) == 0,
                "keeping everything removes nothing")
    }

    @Test("Die Warnung nennt die Zahl der Folgen, die geloescht werden, und die mit Alle ueberschreiben")
    func theWarningCountsEpisodes() {
        let show = PodcastShow(id: "rss:own", title: "Eigene", author: nil, artworkURL: nil,
                               description: nil, feedURL: "https://example.org/own.xml", episodes: [])
        let asked = PodcastGeneralSettings.Question(field: .keepLatest, new: "10", own: [show],
                                                    removedKeepingOwn: 25, removedOverwritingAll: 75)
        #expect(asked.message.contains("25"), "\(asked.message)")
        #expect(asked.message.contains("75"), "\(asked.message)")
        #expect(asked.message.contains("Eigene"), "the shows with their own setting are named")
    }

    @Test("Ein Nutzer ohne Aenderung merkt nichts: ohne allgemeinen Wert gelten die alten Vorgaben")
    func nothingChangesWithoutAChoice() throws {
        try #require(UserDefaults.standard.object(forKey: AppStorageKeys.podcastInboxModeAll) == nil)
        try #require(UserDefaults.standard.object(forKey: AppStorageKeys.podcastEpisodeLimitAll) == nil)
        try #require(UserDefaults.standard.object(forKey: "podcastAutoDownloadModeAll") == nil)
        let showId = "rss:unchosen-\(UUID().uuidString)"
        #expect(AppStorageKeys.podcastInboxModeValue(showId) == "all")
        #expect(AppStorageKeys.podcastEpisodeLimitValue(showId) == 0)
        #expect(PodcastAutoDownload.mode(showId) == .off)
        #expect(PodcastGeneralField.allCases.map(\.general) == ["all", "off", "0"])
        #expect(PodcastGeneralField.allCases.allSatisfy { $0.stored(showId) == nil }, "nothing was written")
    }

    @Test("Zwei allgemeine Werte reisen wie ihre Sendungswerte, Automatisch laden bleibt auf dem Geraet")
    func whatTravels() throws {
        #expect(UserChoiceCatalog.statics[AppStorageKeys.podcastInboxModeAll] == .travels)
        #expect(UserChoiceCatalog.statics[AppStorageKeys.podcastEpisodeLimitAll] == .travels)
        #expect(UserChoiceCatalog.travelingScalars.contains(AppStorageKeys.podcastInboxModeAll))
        #expect(UserChoiceCatalog.travelingScalars.contains(AppStorageKeys.podcastEpisodeLimitAll))
        #expect(!UserChoiceCatalog.travelingScalars.contains("podcastAutoDownloadModeAll"))
        let helpers = try Self.source("Sources/Views/Podcasts/PodcastHelpers.swift")
        #expect(helpers.contains("private static let generalModeKey = \"podcastAutoDownloadModeAll\""),
                "the key the fence names is the key the code writes")
        // Read, not assumed: the automatism's keys are named as staying home.
        for key in ["podcastAutoDownloadModeAll", "podcastAutoDownloadSinceAll"] {
            #expect(UserChoiceCatalog.statics[key] == .device, "\(key)")
            #expect(helpers.contains("\"\(key)\""), "\(key) is the key the code writes")
        }
        for prefix in ["podcastAutoDownload.", "podcastAutoDownloadMode.", "podcastAutoDownloadSince."] {
            #expect(UserChoiceCatalog.prefixes[prefix] == .device, "\(prefix)")
            #expect(helpers.contains("\"\(prefix)\\("), "\(prefix) is the family the code writes")
        }
    }

    @Test("D1 und der Rueckweg: der Podcast-Reiter zeigt die Werte fuer alle, das Blatt jeder Sendung bietet Wie fuer alle", .needsTheSources)
    func theSurfacesAreWired() throws {
        let settings = try Self.source("Sources/Views/SettingsView.swift")
        let tabs = try #require(settings.range(of: "switch tab {"))
        let podcasts = try #require(settings.range(of: "case .podcasts:", range: tabs.upperBound..<settings.endIndex))
        let music = try #require(settings.range(of: "case .music:", range: podcasts.upperBound..<settings.endIndex))
        #expect(settings[podcasts.upperBound..<music.lowerBound].contains("PodcastGeneralSection()"))
        let sheet = try Self.source("Sources/Views/Podcasts/PodcastShowSettingsSheet.swift")
        for field in ["newEpisodes", "autoDownload", "keepLatest"] {
            #expect(sheet.contains("generalPicker(.\(field))"), "\(field) has the way back")
        }
        let picker = try #require(functionBody(of: "private func generalPicker(", in: sheet))
        #expect(picker.contains("Text(\"As for all shows (\\(field.label(field.general)))\").tag(String?.none)"))
        // At large text a menu picker cut "Wie für alle (Alle)" to a few
        // letters; both places show the choices as rows there.
        #expect(picker.contains(".choicesAsRowsWhenLarge()"))
        let section = try Self.source("Sources/Views/Podcasts/PodcastGeneralSection.swift")
        #expect(section.contains(".choicesAsRowsWhenLarge()"))
    }
}
#endif
