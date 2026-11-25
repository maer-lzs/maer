// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation

/// What a folder's start plays.
nonisolated enum PodcastFolderStart: String, CaseIterable, Sendable {
    /// The newest unheard episode of each show (as before).
    case newestPerShow = "newest"
    /// Every unheard episode of every show, oldest first.
    case allUnheard = "all"
}

/// The order of the shows on a folder's page.
nonisolated enum PodcastFolderOrderChoice: String, CaseIterable, Sendable {
    case newestEpisode = "newest"
    case name
    /// The folder's own order, by hand on its page.
    case manual
}

/// The three settings of one folder, each a choice of that folder that
/// travels (`podcastFolderStart.<id>` and its siblings) and leaves with the
/// folder on every device.
nonisolated struct PodcastFolderSettings: Equatable, Sendable {
    var start: PodcastFolderStart = .newestPerShow
    var showsCount = true
    var order: PodcastFolderOrderChoice = .manual

    static let startPrefix = "podcastFolderStart."
    static let countPrefix = "podcastFolderCount."
    static let orderPrefix = "podcastFolderOrder."

    static func keys(folderId: String) -> [String] {
        [startPrefix + folderId, countPrefix + folderId, orderPrefix + folderId]
    }

    /// The settings as stored; a folder without any plays, counts and
    /// orders as before.
    static func read(folderId: String, in defaults: UserDefaults = .standard) -> PodcastFolderSettings {
        var out = PodcastFolderSettings()
        if let raw = defaults.string(forKey: startPrefix + folderId), let start = PodcastFolderStart(rawValue: raw) { out.start = start }
        if let count = defaults.object(forKey: countPrefix + folderId) as? Bool { out.showsCount = count }
        if let raw = defaults.string(forKey: orderPrefix + folderId), let order = PodcastFolderOrderChoice(rawValue: raw) { out.order = order }
        return out
    }

    /// Stores the settings and notes each to travel (`note`, the choice
    /// sync's `noteScalar` in the app).
    static func write(_ settings: PodcastFolderSettings, folderId: String, in defaults: UserDefaults = .standard,
                      note: (String, Any?) -> Void) {
        let values: [(String, Any)] = [(startPrefix + folderId, settings.start.rawValue),
                                       (countPrefix + folderId, settings.showsCount),
                                       (orderPrefix + folderId, settings.order.rawValue)]
        for (key, value) in values {
            defaults.set(value, forKey: key)
            note(key, value)
        }
    }

    /// The folder went here: its settings go, and the removal travels as a
    /// clear so the other devices drop them too.
    static func forget(folderId: String, in defaults: UserDefaults = .standard, note: (String, Any?) -> Void) {
        for key in keys(folderId: folderId) {
            defaults.removeObject(forKey: key)
            note(key, nil)
        }
    }

    /// Folders that left the store, by a delete here or the merge of
    /// another device: their settings go on this device too.
    @MainActor
    static func forgetGone(_ folderIds: some Sequence<String>, noting: Bool) {
        for id in folderIds {
            forget(folderId: id) { key, value in
                if noting { UserChoiceCloudSync.shared.noteScalar(key: key, value: value) }
            }
        }
    }
}

nonisolated enum PodcastFolderPlay {
    /// Every unheard episode of every show, oldest first; offline only
    /// what is downloaded; the same date by the episode's id.
    static func allUnheard(_ shows: [[RoutineRule.Episode]], online: Bool) -> [String] {
        let open: [RoutineRule.Episode] = shows.joined().filter { episode in
            !episode.isPlayed && (online || episode.isDownloaded)
        }
        let ordered = open.sorted { (a: RoutineRule.Episode, b: RoutineRule.Episode) -> Bool in
            if a.pubDate != b.pubDate { return a.pubDate < b.pubDate }
            return a.guid < b.guid
        }
        return ordered.map(\.guid)
    }
}

nonisolated enum PodcastFolderOrder {
    /// The shows of a folder in its chosen order: the newest episode first,
    /// by name, or the folder's own order (as given).
    static func sorted<T>(_ shows: [T], by order: PodcastFolderOrderChoice, key: (T) -> String,
                          title: (T) -> String, newest: (T) -> Double) -> [T] {
        switch order {
        case .manual:
            return shows
        case .newestEpisode:
            return shows.sorted { newest($0) == newest($1) ? key($0) < key($1) : newest($0) > newest($1) }
        case .name:
            return shows.sorted { title($0).localizedCaseInsensitiveCompare(title($1)) == .orderedAscending }
        }
    }
}

nonisolated enum PodcastFolderSort {
    /// The folders among themselves, by the sort of the subscriptions:
    /// recently updated (the newest episode of any of their shows), by
    /// name, or most unplayed; ties by name.
    static func sorted<T>(_ folders: [T], by option: PodcastSortOption, name: (T) -> String,
                          newest: (T) -> Double, unplayed: (T) -> Int) -> [T] {
        func byName(_ a: T, _ b: T) -> Bool { name(a).localizedCaseInsensitiveCompare(name(b)) == .orderedAscending }
        switch option {
        case .zuletztAktualisiert:
            return folders.sorted { newest($0) == newest($1) ? byName($0, $1) : newest($0) > newest($1) }
        case .nameAZ:
            return folders.sorted(by: byName)
        case .meisteUngespielte:
            return folders.sorted { unplayed($0) == unplayed($1) ? byName($0, $1) : unplayed($0) > unplayed($1) }
        }
    }
}
