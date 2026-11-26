// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation

/// Making the folders a preview took: each the way a folder is made by
/// hand (`createFolder` with its first show, `file` for the others), so
/// they travel and stand like any other. Only the preview calls it.
@MainActor
enum SmartFolders {
    /// The subscriptions as the rule reads them: key, title, topics, and
    /// whether a folder already holds the show.
    static func shows(_ subscriptions: [PodcastShow], folders: [MaerPlaylists.Playlist]) -> [SmartFolderSuggestion.Show] {
        let filed = Set(folders.flatMap(\.itemIds).compactMap(PodcastFolder.feedKey(of:)))
        return subscriptions.map { show in
            let key = PodcastIdentity.feedKey(show.feedURL)
            return SmartFolderSuggestion.Show(key: key, title: show.title, categories: show.categories, inFolder: filed.contains(key))
        }
    }

    /// One folder per suggestion with its ticked shows in their order; a
    /// suggestion with none ticked is not made.
    @discardableResult
    static func create(_ suggestions: [SmartFolderSuggestion.Suggestion], ticked: Set<String>, in store: MaerPlaylists) -> [MaerPlaylists.Playlist] {
        var made: [MaerPlaylists.Playlist] = []
        for suggestion in suggestions {
            let keys = suggestion.keys.filter(ticked.contains)
            guard let first = keys.first else { continue }
            let folder = store.createFolder(name: SmartFolderSuggestion.name(for: suggestion.category), show: first)
            for key in keys.dropFirst() { store.file(show: key, into: folder.id) }
            made.append(store.playlist(id: folder.id) ?? folder)
        }
        return made
    }
}
