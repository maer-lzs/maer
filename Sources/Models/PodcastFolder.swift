// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation

/// A podcast folder: a Mär playlist whose entries are shows
/// (`show:<feedKey>`). It travels with the lists, stands in the Podcasts
/// tab (`PlaylistHome`), and starts the newest unheard episode of each show
/// through the rule a routine uses (`rule:newest:<feedKey>`).
nonisolated enum PodcastFolder {
    /// What a list of episodes becomes, and what goes to Up Next once.
    struct Migration: Equatable, Sendable {
        var entries: [String]
        var toUpNext: [String]
    }

    static func entry(feedKey: String) -> String { ItemNamespace.folderShowPrefix + feedKey }

    static func feedKey(of entry: String) -> String? {
        guard entry.hasPrefix(ItemNamespace.folderShowPrefix) else { return nil }
        let key = String(entry.dropFirst(ItemNamespace.folderShowPrefix.count))
        return key.isEmpty ? nil : key
    }

    /// A folder holds at least one show and nothing else.
    static func isFolder(_ itemIds: [String]) -> Bool {
        !itemIds.isEmpty && itemIds.allSatisfy { feedKey(of: $0) != nil }
    }

    /// A list of podcast episodes only, the form before folders.
    static func needsMigration(_ itemIds: [String]) -> Bool {
        !itemIds.isEmpty && itemIds.allSatisfy { MediaFamily.of($0) == .podcast }
    }

    /// The folder of a list of episodes: its shows in the order they first
    /// appear, each once, without a show that stands in another folder (it
    /// stays there). The unheard episodes go to Up Next, those of a show
    /// left out too, so nothing that waited is lost. The same input gives
    /// the same folder on every device; a folder stays as it is.
    static func migrated(_ itemIds: [String], feedKeyOf: (String) -> String?, isHeard: (String) -> Bool,
                         inOtherFolders: Set<String>) -> Migration {
        guard needsMigration(itemIds) else { return Migration(entries: itemIds, toUpNext: []) }
        var seen: Set<String> = []
        var entries: [String] = []
        for id in itemIds {
            guard let key = feedKeyOf(id), !inOtherFolders.contains(key), seen.insert(key).inserted else { continue }
            entries.append(entry(feedKey: key))
        }
        return Migration(entries: entries, toUpNext: itemIds.filter { !isHeard($0) })
    }

    /// The shows that stand in any folder.
    static func foldedShows(in lists: [[String]]) -> Set<String> {
        Set(lists.filter(isFolder).flatMap { $0.compactMap(feedKey(of:)) })
    }

    /// The subscriptions for the loose grid: a show in a folder is there.
    static func loose(_ feedKeys: [String], folded: Set<String>) -> [String] {
        feedKeys.filter { !folded.contains($0) }
    }

    /// The tile's number: the new episodes of all the folder's shows.
    static func newCount(_ itemIds: [String], new: (String) -> Int) -> Int {
        itemIds.compactMap(feedKey(of:)).reduce(0) { $0 + new($1) }
    }

    /// The routine rules a folder starts through: the newest of each show.
    static func ruleIds(_ itemIds: [String]) -> [String] {
        itemIds.compactMap(feedKey(of:)).compactMap { RoutineRule(kind: .newest, feedKey: $0)?.id }
    }
}
