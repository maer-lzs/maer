// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation

/// The catalog titles this device resolved for playback, kept with their
/// metadata so a title names itself from the first display on, also after
/// a restart before anything is resolved again. Only what names a title
/// (metadata and duration) is kept, never its tracks; newest first, at most
/// `cap`.
nonisolated enum CatalogKeptItems {
    static let cap = 100

    /// `kept` with `item` first. An item without a title adds nothing; the
    /// same id stands once.
    static func adding(_ item: LibraryItem, to kept: [LibraryItem], cap: Int = cap) -> [LibraryItem] {
        guard let media = item.media, !(media.metadata?.title ?? "").isEmpty else { return kept }
        let slim = LibraryItem(id: item.id,
                               media: LibraryItemMedia(metadata: media.metadata, duration: media.duration,
                                                       chapters: nil, tracks: nil),
                               addedAt: item.addedAt)
        return Array(([slim] + kept.filter { $0.id != item.id }).prefix(cap))
    }
}
