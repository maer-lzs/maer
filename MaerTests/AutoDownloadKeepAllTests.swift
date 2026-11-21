// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// The choice All for the episodes the automatic download keeps: the
/// highest number, so the hold of every older build reads it without a new
/// type, loads every wanted episode and deletes nothing for the count. In
/// order it can be the whole archive, and the choice says so.
@MainActor
struct AutoDownloadKeepAllTests {
    typealias Rules = PodcastAutoDownloadRules

    @Test("All is the last choice of the count, the highest number, and reads as All")
    func allIsAChoice() {
        #expect(Rules.keepAll == Int.max)
        #expect(Rules.keepChoices == [1, 3, 5, 10, Rules.keepAll])
        let field = PodcastGeneralField.keepDownloaded
        #expect(field.choices.last == String(Int.max))
        #expect(field.label(String(Rules.keepAll)) == String(localized: "All"))
        #expect(field.label("5") == "5")
    }

    @Test("All loads every wanted episode in both directions and deletes nothing for the count; a download by hand stays")
    func allHoldsEverything() {
        let own = [Rules.Owned(id: "e2", pubDate: 2, isProtected: false),
                   Rules.Owned(id: "e9", pubDate: 9, isProtected: false)]
        let downloaded: Set<String> = ["e2", "e9", "e3"]
        let newest = Rules.hold(wanted: ["e9", "e8", "e7"], isDownloaded: { downloaded.contains($0) },
                                own: own, direction: .newest, limit: Rules.keepAll)
        #expect(newest == Rules.Hold(fetch: ["e8", "e7"], drop: []))
        let inOrder = Rules.hold(wanted: ["e7", "e8", "e9"], isDownloaded: { downloaded.contains($0) },
                                 own: own, direction: .inOrder, limit: Rules.keepAll)
        #expect(inOrder == Rules.Hold(fetch: ["e7", "e8"], drop: []))
    }

    @Test("a stored All is read back per show and for all shows, and the field writes and reads it")
    func allIsStoredAsTheNumber() {
        let name = "keep-all-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { UserDefaults().removePersistentDomain(forName: name) }
        defaults.set(Int.max, forKey: PodcastAutoDownload.keepKey("feed:all"))
        defaults.set(Int.max, forKey: PodcastAutoDownload.generalKeepKey)
        #expect(PodcastAutoDownload.storedKeep("feed:all", defaults: defaults) == Rules.keepAll)
        #expect(PodcastAutoDownload.keep("feed:follows", defaults: defaults) == Rules.keepAll)
        #expect(Int(String(Rules.keepAll)) == Rules.keepAll, "the field's raw value reads back as the number")
    }

    @Test("the sentence under the choice stands only in order with All")
    func theArchiveSentence() {
        #expect(Rules.warnsOfArchive(direction: .inOrder, keep: Rules.keepAll))
        #expect(!Rules.warnsOfArchive(direction: .newest, keep: Rules.keepAll))
        #expect(!Rules.warnsOfArchive(direction: .inOrder, keep: 10))
        #expect(!Rules.warnsOfArchive(direction: .newest, keep: 3))
    }

    @Test("the show's sheet and the section for all shows ask the rule through one reading and say one sentence, with its German words", .needsTheSources)
    func theSentenceStands() throws {
        func code(_ file: String) throws -> String {
            SyncContractFenceTests.stripped(try String(contentsOf: SourceTree.root.appendingPathComponent(file), encoding: .utf8))
        }
        for file in ["Sources/Views/Podcasts/PodcastShowSettingsSheet.swift", "Sources/Views/Podcasts/PodcastGeneralSection.swift"] {
            let surface = try code(file)
            #expect(surface.contains("PodcastGeneralSettings.warnsOfArchive("), "\(file) does not ask the one reading")
            #expect(surface.contains("Text(PodcastGeneralSettings.archiveWarning)"), "\(file) says a sentence of its own")
        }
        #expect(try code("Sources/ViewModels/PodcastGeneralSettings.swift").contains("PodcastAutoDownloadRules.warnsOfArchive("),
                "the one reading does not ask the rule")
        let catalog = try String(contentsOf: SourceTree.root.appendingPathComponent("Sources/Localizable.xcstrings"), encoding: .utf8)
        let json = try #require(try JSONSerialization.jsonObject(with: Data(catalog.utf8)) as? [String: Any])
        let strings = try #require(json["strings"] as? [String: Any])
        let entry = try #require(strings["Loads every episode of the show from where you are, which can be the whole archive."] as? [String: Any],
                                 "the sentence is not in the catalogue")
        let german = ((entry["localizations"] as? [String: Any])?["de"] as? [String: Any])?["stringUnit"] as? [String: Any]
        #expect(german?["value"] as? String == "Lädt jede Folge der Sendung ab deiner Stelle, das kann das ganze Archiv sein.")
    }
}
#endif
