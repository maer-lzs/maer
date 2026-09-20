// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation

/// Which media family an item id belongs to. The ONE place that maps a
/// namespace to a kind.
///
/// Every case is defined POSITIVELY. The book case used to be the leftover
/// ("everything that is not podcast, music or radio"), so the four catalogue
/// namespaces silently counted as books: tapping the player title sent a
/// netlabel album to the audiobook tab and opened a detail page for an item
/// the audiobook library does not know. No error, no log, an empty screen.
///
/// A namespace that is not listed here is `.unknown`. That is deliberate and
/// must stay visible: an unknown family gets no affordance that leads nowhere,
/// and it is logged where it surfaces.
nonisolated enum MediaFamily: String, CaseIterable, Sendable {
    case book
    case podcast
    case music
    case radio
    /// Free catalogues (LibriVox, Internet Archive, Jamendo, Gutenberg). One
    /// family, because their pages are the same: an item resolves to its
    /// catalogue page, whether it is a reading, a radio play or an album.
    case catalog
    case unknown

    /// The namespaces each family owns. Books carry no prefix of their own
    /// (Audiobookshelf ids are bare), which is exactly why they may not be the
    /// fallback. See `of(_:)`.
    static func prefixes(for family: MediaFamily) -> [String] {
        switch family {
        case .podcast: return ["rss:", "abspod:"]
        case .music:   return ["sub:", "jf:"]
        case .radio:   return ["radio:"]
        case .catalog: return [FreeCatalog.librivoxPrefix, FreeCatalog.archivePrefix,
                               FreeCatalog.jamendoPrefix, FreeCatalog.gutenbergPrefix]
        case .book:    return ["local:"]
        case .unknown: return []
        }
    }

    /// Every namespace the app knows. A new family must appear here, otherwise
    /// the contract test fails.
    static var knownPrefixes: [String] {
        allCases.flatMap { prefixes(for: $0) }
    }

    /// The ONE positive membership test of the BOOKS tab's library rows
    /// (Continue, Recently Added, Rediscover, full pages. Every surface that
    /// shows "my audiobook library" asks HERE, never re-derives).
    ///
    /// The catalog family is one family, its members are not: `lv:`/`gut:`
    /// are readings (books), `jam:` is music by type, `lva:` is mixed and
    /// decides per item. A song-addressed id (`lva:x#i`) is a track (music),
    /// a whole work follows its started FORM; without a form the book side is
    /// the honest home (the catalog's origin). `.unknown` is never quietly
    /// filed. Callers log it where it surfaces.
    static func booksTabMember(_ id: String,
                               markedForm: ProgressMark.StartedForm?) -> Bool {
        switch of(id) {
        case .book: return true
        case .podcast, .music, .radio, .unknown: return false
        case .catalog:
            if id.hasPrefix(FreeCatalog.jamendoPrefix) { return false }
            if id.hasPrefix(FreeCatalog.archivePrefix) {
                if id.contains(CatalogSongID.separator) { return false }
                return markedForm != .album
            }
            return true
        }
    }

    /// Music by FORM, the way the player's tools decide it: the music
    /// family, or a catalogue item that is not a reading (an album, a song).
    static func isMusicByForm(_ id: String, markedForm: ProgressMark.StartedForm? = nil) -> Bool {
        switch of(id) {
        case .music: return true
        case .catalog: return !booksTabMember(id, markedForm: markedForm)
        default: return false
        }
    }

    /// How many of these ids are music. ONE rule, because the number stands
    /// on two surfaces now (the music tab's Downloaded tile and the search
    /// deck's), and a count that comes out differently in two places is a
    /// defect of its own, not a detail.
    static func musicCount(in ids: some Sequence<String>) -> Int {
        ids.reduce(into: 0) { total, id in if of(id) == .music { total += 1 } }
    }

    static func of(_ id: String) -> MediaFamily {
        for family in allCases where family != .unknown {
            if prefixes(for: family).contains(where: { id.hasPrefix($0) }) { return family }
        }
        // A bare id is an Audiobookshelf item. The only family without a
        // namespace of its own. Anything that carries an UNKNOWN namespace is
        // not quietly filed here.
        return id.contains(":") ? .unknown : .book
    }
}
