// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation

nonisolated enum PodcastFolderStart: String, CaseIterable, Sendable { case newestPerShow = "newest", allUnheard = "all" }
nonisolated enum PodcastFolderOrderChoice: String, CaseIterable, Sendable { case newestEpisode = "newest", name, manual }

nonisolated struct PodcastFolderSettings: Equatable, Sendable {
    var start: PodcastFolderStart = .newestPerShow
    var showsCount = true
    var order: PodcastFolderOrderChoice = .manual

    static func keys(folderId: String) -> [String] {
        ["podcastFolderStart.\(folderId)", "podcastFolderCount.\(folderId)", "podcastFolderOrder.\(folderId)"]
    }
    static func read(folderId: String, in defaults: UserDefaults = .standard) -> PodcastFolderSettings { PodcastFolderSettings() }
    static func write(_ settings: PodcastFolderSettings, folderId: String, in defaults: UserDefaults = .standard,
                      note: (String, Any?) -> Void) {}
    static func forget(folderId: String, in defaults: UserDefaults = .standard, note: (String, Any?) -> Void) {}
}

nonisolated enum PodcastFolderPlay {
    static func allUnheard(_ shows: [[RoutineRule.Episode]], online: Bool) -> [String] { [] }
}

nonisolated enum PodcastFolderOrder {
    static func sorted<T>(_ shows: [T], by order: PodcastFolderOrderChoice, key: (T) -> String,
                          title: (T) -> String, newest: (T) -> Double) -> [T] { shows }
}

nonisolated enum PodcastFolderSort {
    static func sorted<T>(_ folders: [T], by option: PodcastSortOption, name: (T) -> String,
                          newest: (T) -> Double, unplayed: (T) -> Int) -> [T] { folders }
}
