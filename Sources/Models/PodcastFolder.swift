// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation

/// A podcast folder: a Mär playlist whose entries are shows.
nonisolated enum PodcastFolder {
    struct Migration: Equatable, Sendable {
        var entries: [String]
        var toUpNext: [String]
    }

    static func entry(feedKey: String) -> String { "" }
    static func feedKey(of entry: String) -> String? { nil }
    static func isFolder(_ itemIds: [String]) -> Bool { false }
    static func needsMigration(_ itemIds: [String]) -> Bool { false }
    static func migrated(_ itemIds: [String], feedKeyOf: (String) -> String?, isHeard: (String) -> Bool,
                         inOtherFolders: Set<String>) -> Migration { Migration(entries: itemIds, toUpNext: []) }
    static func foldedShows(in lists: [[String]]) -> Set<String> { [] }
    static func loose(_ feedKeys: [String], folded: Set<String>) -> [String] { feedKeys }
    static func newCount(_ itemIds: [String], new: (String) -> Int) -> Int { 0 }
    static func ruleIds(_ itemIds: [String]) -> [String] { [] }
}
