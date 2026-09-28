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

    @Test("Die Frage nennt die Sendungen mit eigener Einstellung und den neuen Wert")
    func theQuestionNamesTheShows() {
        let show = PodcastShow(id: "rss:own", title: "Eigene", author: nil, artworkURL: nil,
                               description: nil, feedURL: "https://example.org/own.xml", episodes: [])
        let asked = PodcastGeneralSettings.Question(field: .newEpisodes, new: "off", own: [show])
        #expect(asked.message.contains("Eigene"), "the shows with their own setting are named")
        #expect(asked.message.contains(PodcastGeneralField.newEpisodes.label("off")), "\(asked.message)")
    }

    @Test("Ein Nutzer ohne Aenderung merkt nichts: ohne allgemeinen Wert gelten die alten Vorgaben")
    func nothingChangesWithoutAChoice() throws {
        try #require(UserDefaults.standard.object(forKey: AppStorageKeys.podcastInboxModeAll) == nil)
        for key in ["podcastAutoDownloadModeAll", "podcastAutoDownloadOnAll",
                    "podcastAutoDownloadDirectionAll", "podcastAutoDownloadKeepAll"] {
            try #require(UserDefaults.standard.object(forKey: key) == nil, "\(key) is set, the case measures nothing")
        }
        let showId = "rss:unchosen-\(UUID().uuidString)"
        #expect(AppStorageKeys.podcastInboxModeValue(showId) == "all")
        #expect(!PodcastAutoDownload.isEnabled(showId))
        #expect(PodcastGeneralField.allCases.map(\.general) == ["all", "off", "newest", "3", "60"])
        #expect(PodcastGeneralField.allCases.allSatisfy { $0.stored(showId) == nil }, "nothing was written")
    }

    @Test("Neue Folgen und die Richtung reisen, Ein/Aus und Anzahl der Automatik bleiben auf dem Geraet")
    func whatTravels() throws {
        #expect(UserChoiceCatalog.statics[AppStorageKeys.podcastInboxModeAll] == .travels)
        #expect(UserChoiceCatalog.travelingScalars.contains(AppStorageKeys.podcastInboxModeAll))
        #expect(UserChoiceCatalog.statics["podcastAutoDownloadDirectionAll"] == .travels)
        #expect(UserChoiceCatalog.travelingScalars.contains("podcastAutoDownloadDirectionAll"))
        #expect(UserChoiceCatalog.prefixes["podcastAutoDownloadDirection."] == .travels)
        #expect(UserChoiceCatalog.travelingPrefixes.contains("podcastAutoDownloadDirection."))
        #expect(!UserChoiceCatalog.travelingScalars.contains("podcastAutoDownloadModeAll"))
        let helpers = try Self.source("Sources/Views/Podcasts/PodcastHelpers.swift")
        #expect(helpers.contains("static let generalDirectionKey = \"podcastAutoDownloadDirectionAll\""),
                "the key the fence names is the key the code writes")
        // Read, not assumed: the automatism's other keys are named as staying home.
        for key in ["podcastAutoDownloadModeAll", "podcastAutoDownloadSinceAll",
                    "podcastAutoDownloadOnAll", "podcastAutoDownloadKeepAll"] {
            #expect(UserChoiceCatalog.statics[key] == .device, "\(key)")
            #expect(helpers.contains("\"\(key)\""), "\(key) is the key the code writes")
        }
        for prefix in ["podcastAutoDownload.", "podcastAutoDownloadMode.", "podcastAutoDownloadSince.",
                       "podcastAutoDownloadKeep."] {
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
        for field in ["newEpisodes", "autoDownload", "direction", "keepDownloaded"] {
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
