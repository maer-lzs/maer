// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation

/// Where the book route finds the entry its page shows. The route asked the
/// loaded grid alone, and a book outside it (the playing title before the
/// grid paged in, a title only on a shelf) pushed a page that drew nothing.
/// Now it asks the grid and the shelves (with progress), then the source
/// that knows the item, then the player; nil means an honest empty state.
nonisolated enum BookRouteEntry {
    static func resolve(_ itemId: String, shelved: LibraryEntry?, known: LibraryItem?,
                        playing: LibraryItem?) -> LibraryEntry? {
        if let shelved, shelved.id == itemId { return shelved }
        if let item = [known, playing].compactMap({ $0 }).first(where: { $0.id == itemId }) {
            return LibraryEntry(item: item, progress: nil)
        }
        return nil
    }
}
