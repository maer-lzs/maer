// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Foundation
import Testing
@testable import Maer

/// Folders suggested from the topic each show names in its feed
/// (`itunes:category`, already read with the feed): loose shows only, a
/// suggestion from two shows on, a hint from eight subscriptions on, and
/// nothing changes without a tap.
@MainActor
struct SmartFolderTests {
    typealias Show = SmartFolderSuggestion.Show

    static let shows: [Show] = [
        Show(key: "a", title: "Alpha News", categories: ["News", "Daily News"], inFolder: false),
        Show(key: "b", title: "Bravo", categories: ["News"], inFolder: false),
        Show(key: "c", title: "Crime One", categories: ["True Crime"], inFolder: false),
        Show(key: "d", title: "Crime Two", categories: ["True Crime"], inFolder: false),
        Show(key: "e", title: "Crime Three", categories: ["True Crime"], inFolder: false),
        Show(key: "f", title: "Filed", categories: ["News"], inFolder: true),
        Show(key: "g", title: "Lone", categories: ["Comedy"], inFolder: false),
        Show(key: "h", title: "Untold", categories: nil, inFolder: false),
    ]

    @Test("loose shows by their first topic, a suggestion from two on, largest first; a show in a folder or without a topic stays out")
    func groups() {
        let found = SmartFolderSuggestion.suggest(Self.shows)
        #expect(found.map(\.category) == ["True Crime", "News"])
        #expect(found.map(\.keys) == [["c", "d", "e"], ["a", "b"]])
    }

    @Test("the subtopic does not make a group of its own")
    func subtopic() {
        let found = SmartFolderSuggestion.suggest([Self.shows[0], Self.shows[1]])
        #expect(found.count == 1 && found.first?.category == "News")
    }

    @Test("the name is the topic in the device's language; a topic outside Apple's list stands as given")
    func names() {
        #expect(SmartFolderSuggestion.name(for: "True Crime") == String(localized: "True Crime"))
        #expect(SmartFolderSuggestion.name(for: "Society & Culture") == String(localized: "Society & Culture"))
        #expect(SmartFolderSuggestion.name(for: "Hörspiel") == "Hörspiel")
        #expect(SmartFolderSuggestion.appleTopics.count == 19)
    }

    @Test("the hint: from eight subscriptions with a suggestion, never after it was put away on this device")
    func hint() {
        #expect(!SmartFolderSuggestion.showsHint(subscriptions: 7, suggestions: 2, dismissed: false))
        #expect(SmartFolderSuggestion.showsHint(subscriptions: 8, suggestions: 1, dismissed: false))
        #expect(!SmartFolderSuggestion.showsHint(subscriptions: 8, suggestions: 0, dismissed: false))
        #expect(!SmartFolderSuggestion.showsHint(subscriptions: 20, suggestions: 3, dismissed: true))
        #expect(UserChoiceCatalog.statics[AppStorageKeys.smartFoldersHintDismissed] == .device, "the put away hint does not travel")
    }

    @Test("taken whole or in part: one folder per suggestion with the ticked shows in their order; a suggestion with none ticked is not made")
    func take() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("smart-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = MaerPlaylists(database: MaerDatabase(path: directory.appendingPathComponent("s.sqlite").path))
        let found = SmartFolderSuggestion.suggest(Self.shows)
        let made = SmartFolders.create(found, ticked: ["c", "e", "a", "b"], in: store)
        #expect(made.count == 2)
        let folders = store.playlists.filter { PodcastFolder.isFolder($0.itemIds) }
        #expect(folders.count == 2)
        let crime = try #require(folders.first { $0.name == SmartFolderSuggestion.name(for: "True Crime") })
        #expect(crime.itemIds.compactMap(PodcastFolder.feedKey(of:)) == ["c", "e"])
        let none = SmartFolders.create(found, ticked: [], in: store)
        #expect(none.isEmpty && store.playlists.filter { PodcastFolder.isFolder($0.itemIds) }.count == 2)
    }

    @Test("Fence: the rule and the hint write nothing and ask nothing; folders are made only from the preview, the way a folder is made by hand", .needsTheSources)
    func nothingWithoutATap() throws {
        let rule = SyncContractFenceTests.stripped(try String(contentsOf: SourceTree.root
            .appendingPathComponent("Sources/Models/SmartFolderSuggestion.swift"), encoding: .utf8))
        for word in ["createFolder", ".set(", "refresh", "fetch", "URLSession", "HTTP."] {
            #expect(!rule.contains(word), "the rule reaches \(word)")
        }
        var makers: [String] = []
        for file in ProjectFileIntegrityTests.sourceFiles() {
            let text = SyncContractFenceTests.stripped(try SourceTree.text(file))
            if text.contains("SmartFolders.create(") { makers.append(file.lastPathComponent) }
        }
        #expect(makers == ["SmartFolderSheet.swift"], "\(makers)")
        let make = SyncContractFenceTests.stripped(try String(contentsOf: SourceTree.root
            .appendingPathComponent("Sources/Providers/SmartFolders.swift"), encoding: .utf8))
        #expect(make.contains("store.createFolder(name:") && make.contains("store.file(show:"))
    }
}
#endif
