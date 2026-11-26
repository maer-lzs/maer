// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Foundation
import Testing
@testable import Maer

/// Each podcast folder carries three settings of its own (what its start
/// plays, whether its tile counts the new episodes, the order of its
/// shows), travelling as choices of that folder; the folders among
/// themselves follow one sort, on their page and in their row, travelling
/// as the books' sort does.
@MainActor
struct FolderSettingsTests {
    static func suite() -> (UserDefaults, String) {
        let name = "folder-settings-\(UUID().uuidString)"
        return (UserDefaults(suiteName: name)!, name)
    }

    // MARK: The settings of one folder

    @Test("a folder without settings plays as today, counts, and keeps its own order")
    func defaults() {
        let (defaults, name) = Self.suite()
        defer { UserDefaults().removePersistentDomain(forName: name) }
        let settings = PodcastFolderSettings.read(folderId: "F1", in: defaults)
        #expect(settings == PodcastFolderSettings(start: .newestPerShow, showsCount: true, order: .manual))
    }

    @Test("written settings read back, and a folder that goes takes its settings with it")
    func writeAndForget() {
        let (defaults, name) = Self.suite()
        defer { UserDefaults().removePersistentDomain(forName: name) }
        var noted: [String: Any?] = [:]
        let chosen = PodcastFolderSettings(start: .allUnheard, showsCount: false, order: .name)
        PodcastFolderSettings.write(chosen, folderId: "F1", in: defaults) { noted[$0] = $1 }
        #expect(PodcastFolderSettings.read(folderId: "F1", in: defaults) == chosen)
        #expect(Set(noted.keys) == Set(PodcastFolderSettings.keys(folderId: "F1")), "every setting is noted to travel")
        noted = [:]
        PodcastFolderSettings.forget(folderId: "F1", in: defaults) { noted[$0] = $1 }
        #expect(PodcastFolderSettings.keys(folderId: "F1").allSatisfy { defaults.object(forKey: $0) == nil })
        #expect(noted.count == 3 && noted.values.allSatisfy { $0 == nil }, "the removal travels as a clear")
    }

    @Test("the settings and the sort of the folders are choices that travel")
    func theyTravel() {
        for key in PodcastFolderSettings.keys(folderId: "F1") {
            let prefix = String(key.prefix(upTo: key.firstIndex(of: ".")!)) + "."
            #expect(UserChoiceCatalog.prefixes[prefix] == .travels, "\(prefix)")
        }
        #expect(UserChoiceCatalog.statics[AppStorageKeys.podcastFoldersSort] == .travels)
    }

    @Test("two devices: a setting chosen on one stands on the other, and a folder deleted on one clears it on the other")
    func twoDevices() {
        let cloud = CountingChoiceCloud()
        func device(_ now: Double) -> (UserChoiceCloudSync, UserDefaults, String) {
            let (defaults, name) = Self.suite()
            var clock = now
            return (UserChoiceCloudSync(defaults: defaults, cloud: cloud, syncEnabled: { true },
                                        now: { clock += 1; return clock }, idFormSettled: { true }), defaults, name)
        }
        let (a, aDefaults, aName) = device(10_000)
        let (b, bDefaults, bName) = device(20_000)
        defer {
            UserDefaults().removePersistentDomain(forName: aName)
            UserDefaults().removePersistentDomain(forName: bName)
        }
        let chosen = PodcastFolderSettings(start: .allUnheard, showsCount: false, order: .newestEpisode)
        PodcastFolderSettings.write(chosen, folderId: "F1", in: aDefaults) { a.noteScalar(key: $0, value: $1) }
        a.reconcile()
        b.reconcile()
        #expect(PodcastFolderSettings.read(folderId: "F1", in: bDefaults) == chosen)
        PodcastFolderSettings.forget(folderId: "F1", in: aDefaults) { a.noteScalar(key: $0, value: $1) }
        a.reconcile()
        b.reconcile()
        #expect(PodcastFolderSettings.keys(folderId: "F1").allSatisfy { bDefaults.object(forKey: $0) == nil },
                "the deleted folder's settings stay on the other device")
    }

    @Test("Fence: a folder that goes, here or by the merge of another device, takes its settings with it", .needsTheSources)
    func goneFolderForgets() throws {
        let store = SyncContractFenceTests.stripped(try String(contentsOf: SourceTree.root
            .appendingPathComponent("Sources/Providers/MaerPlaylists.swift"), encoding: .utf8))
        #expect(store.components(separatedBy: "PodcastFolderSettings.forgetGone(").count - 1 == 2,
                "the delete and the merge both forget a folder's settings")
    }

    // MARK: What the start plays

    static func episode(_ guid: String, _ day: Int, played: Bool = false, downloaded: Bool = true) -> RoutineRule.Episode {
        RoutineRule.Episode(guid: guid, pubDate: Double(day) * 86_400,
                            isPlayed: played, isStarted: false, isDownloaded: downloaded)
    }

    @Test("all unheard: every unheard episode of every show, oldest first; heard ones stay out; offline only what is downloaded")
    func allUnheard() {
        let shows = [
            [Self.episode("a1", 1), Self.episode("a2", 5, played: true), Self.episode("a3", 9)],
            [Self.episode("b1", 3), Self.episode("b2", 7, downloaded: false)],
            [Self.episode("c1", 2, played: true)],
        ]
        #expect(PodcastFolderPlay.allUnheard(shows, online: true) == ["a1", "b1", "b2", "a3"])
        #expect(PodcastFolderPlay.allUnheard(shows, online: false) == ["a1", "b1", "a3"])
        #expect(PodcastFolderPlay.allUnheard([], online: true).isEmpty)
    }

    @Test("Fence: a folder's start asks its setting", .needsTheSources)
    func startAsks() throws {
        let playback = SyncContractFenceTests.stripped(try String(contentsOf: SourceTree.root
            .appendingPathComponent("Sources/Providers/RoutinePlayback.swift"), encoding: .utf8))
        #expect(playback.contains("PodcastFolderSettings.read(folderId: list.id).start == .allUnheard"))
        #expect(playback.contains("PodcastFolderPlay.allUnheard("))
    }

    @Test("the line under the folder's play says what its start plays")
    func startLine() {
        #expect(PodcastFolderPlay.line(for: .newestPerShow) == String(localized: "Plays the newest unheard episode of each show, by date."))
        #expect(PodcastFolderPlay.line(for: .allUnheard) == String(localized: "Plays every unheard episode, oldest first."))
    }

    @Test("Fence: the folder page takes its line from the folder's setting", .needsTheSources)
    func startLineAsks() throws {
        let views = SyncContractFenceTests.stripped(try String(contentsOf: SourceTree.root
            .appendingPathComponent("Sources/Views/Podcasts/PodcastFolderViews.swift"), encoding: .utf8))
        #expect(views.contains("PodcastFolderPlay.line(for: PodcastFolderSettings.read(folderId: folderId).start)"))
        #expect(!views.contains("Text(\"Plays the newest unheard episode of each show, by date.\")"), "the page says one start whatever the setting")
    }

    // MARK: The order of the shows in a folder

    @Test("the shows of a folder: newest episode first, by name, or in the folder's own order")
    func showOrder() {
        let shows = [(key: "b", title: "Beta", newest: 100.0), (key: "a", title: "alpha", newest: 300.0),
                     (key: "c", title: "Gamma", newest: 200.0)]
        #expect(PodcastFolderOrder.sorted(shows, by: .manual, key: \.key, title: \.title, newest: \.newest).map(\.key) == ["b", "a", "c"])
        #expect(PodcastFolderOrder.sorted(shows, by: .newestEpisode, key: \.key, title: \.title, newest: \.newest).map(\.key) == ["a", "c", "b"])
        #expect(PodcastFolderOrder.sorted(shows, by: .name, key: \.key, title: \.title, newest: \.newest).map(\.key) == ["a", "b", "c"])
    }

    // MARK: The order of the folders

    @Test("the folders: recently updated first by default, by name, or most unplayed; ties by name")
    func folderSort() {
        let folders = [(id: "1", name: "Morgens", newest: 100.0, unplayed: 3),
                       (id: "2", name: "abends", newest: 300.0, unplayed: 1),
                       (id: "3", name: "Wochenende", newest: 200.0, unplayed: 3)]
        func ids(_ option: PodcastSortOption) -> [String] {
            PodcastFolderSort.sorted(folders, by: option, name: \.name, newest: \.newest, unplayed: \.unplayed).map(\.id)
        }
        #expect(ids(.zuletztAktualisiert) == ["2", "3", "1"])
        #expect(ids(.nameAZ) == ["2", "1", "3"])
        #expect(ids(.meisteUngespielte) == ["1", "3", "2"])
    }

    @Test("Fence: the page of all folders carries the sort, the row follows it, the tile counts only when asked, the edit sheet holds the settings", .needsTheSources)
    func surfaces() throws {
        let views = SyncContractFenceTests.stripped(try String(contentsOf: SourceTree.root
            .appendingPathComponent("Sources/Views/Podcasts/PodcastFolderViews.swift"), encoding: .utf8))
        #expect(views.contains("SectionSortControl(activeLabel:"), "the page of all folders has no sort")
        // One sort for the row and the page: the row's `ordered` asks the
        // rule, the page asks the row's `ordered`.
        #expect(views.contains("PodcastFolderSort.sorted(") && views.contains("PodcastFolderRow.ordered(all, by: sort,"),
                "the row and the page do not share the sort")
        #expect(views.contains("PodcastFolderSettings.read(folderId: folder.id).showsCount"), "the tile counts whatever the setting")
        #expect(views.contains("PodcastFolderOrder.sorted("), "the folder page keeps one order")
        let sheet = SyncContractFenceTests.stripped(try String(contentsOf: SourceTree.root
            .appendingPathComponent("Sources/Views/Podcasts/AddShowToFolderSheet.swift"), encoding: .utf8))
        #expect(sheet.contains("PodcastFolderSettings.write("), "saving the edit keeps no settings")
    }
}
#endif
