// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation

/// Where the book route finds the entry its page shows, also for a book the
/// loaded grid does not hold (the playing title before the grid pages in, a
/// title only on a shelf): the grid and the shelves (with progress), then
/// the source that knows the item, then the player. A candidate that names
/// its title wins over one without metadata (a catalog title can stand
/// there by its id alone), the shelf's progress stays. Nil
/// means the route shows an empty state. Beside the library's view model,
/// whose entry it answers with.
nonisolated enum BookRouteEntry {
    static func resolve(_ itemId: String, shelved: LibraryEntry?, known: LibraryItem?,
                        playing: LibraryItem?) -> LibraryEntry? {
        let shelf = shelved?.id == itemId ? shelved : nil
        let items = [shelf?.item, known, playing].compactMap { $0 }.filter { $0.id == itemId }
        guard let item = items.first(where: BookPageItem.namesItself) ?? items.first else { return nil }
        return LibraryEntry(item: item, progress: shelf?.progress)
    }
}

/// The item a book page names: the entry's, and where that carries no
/// title the detail the page loaded, which does.
nonisolated enum BookPageItem {
    static func namesItself(_ item: LibraryItem) -> Bool {
        !(item.media?.metadata?.title ?? "").isEmpty
    }

    static func shown(entry: LibraryItem, detail: LibraryItemDetail?) -> LibraryItem {
        guard !namesItself(entry), let detail, !(detail.media.metadata?.title ?? "").isEmpty else { return entry }
        return LibraryItem(id: entry.id, media: detail.media, addedAt: entry.addedAt)
    }
}
