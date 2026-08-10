// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation

/// What an archive.org item IS — one work in parts, or an album of tracks.
///
/// The form used to be decided by the ROUTE: opened from the music tab it was
/// an album, opened from the books tab a work. The same item therefore had two
/// forms depending on where it was tapped, and the mixed rows (shuffle, trove,
/// search) can reach either. A reading opened through the album route got a
/// position per track instead of one position for the work.
///
/// The item's COLLECTIONS decide it instead. They ride along on both endpoints
/// the app already calls — measured over the five queries the app itself runs:
/// the search index answered with `collection` for 250 of 250 items and always
/// contained the queried collection; the metadata endpoint carries it too.
///
/// Both lists are positive and hold only collections the app QUERIES. A name
/// nobody queries cannot identify an item that got in, so it would be
/// unmeasured breadth. Everything else is `nil` — "not decidable here", and
/// the caller keeps its own default rather than guessing.
nonisolated enum ArchiveItemForm: String, Sendable {
    /// One work in parts: a reading in chapters, a series bundle of episodes.
    /// The work holds one position; a part is a section of it.
    case work
    /// An album of tracks. Each track is an item of its own — own position,
    /// own "played", can be queued and put into a playlist.
    case album

    /// Collections whose items are works. These are the three the app queries
    /// for its book and radio-play areas.
    static let workCollections: Set<String> = ["librivoxaudio", "oldtimeradio", "audio_bookspoetry"]

    /// Collections whose items are albums — the two music areas on archive.org.
    static let albumCollections: Set<String> = ["netlabels", "georgeblood"]

    /// The form, or nil when the collections say nothing about it.
    ///
    /// Work wins when an item is in both, and the asymmetry is the reason: a
    /// work rendered as an album splits its ONE position into a mark per track,
    /// so where the listener was is gone. An album rendered as a work only
    /// loses granularity — the position survives. Of the two possible mistakes
    /// only one is reversible.
    static func of(collections: [String]) -> ArchiveItemForm? {
        if collections.contains(where: { workCollections.contains($0) }) { return .work }
        if collections.contains(where: { albumCollections.contains($0) }) { return .album }
        return nil
    }

    /// Is this item a curated radio-play bundle? Positive, from the collection
    /// — it used to be an in-memory set that only the radio-play row filled, so
    /// the same item was a bundle when it came from that row and an ordinary
    /// item when it came from search, a playlist or a cold start.
    static func isRadioPlayBundle(collections: [String]) -> Bool {
        collections.contains("oldtimeradio")
    }
}
