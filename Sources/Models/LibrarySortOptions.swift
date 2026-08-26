// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation

// Per-tab sort/filter options (Teil 2). Deliberately NOT a shared protocol.
// Three small independent enums following the audiobook `SortOption` pattern
// (rawValue = stable persistence key, `label` localized). The audiobook
// `SortOption`/`FilterOption` live in LibraryViewModel and stay the reference.

/// Podcast show-grid sort ("Recently updated" grid only; curated sections and
/// per-show episode order are untouched).
nonisolated enum PodcastSortOption: String, CaseIterable, Identifiable {
    case zuletztAktualisiert = "Zuletzt aktualisiert"
    case nameAZ = "Name A-Z"
    case meisteUngespielte = "Meiste ungespielte"
    var id: String { rawValue }

    var label: String {
        switch self {
        case .zuletztAktualisiert: return String(localized: "Recently Updated")
        case .nameAZ: return String(localized: "Name A–Z")
        case .meisteUngespielte: return String(localized: "Most Unplayed")
        }
    }
}

/// Podcast show-grid filter.
nonisolated enum PodcastFilterOption: String, CaseIterable, Identifiable {
    case alle = "Alle"
    case mitDownloads = "Nur mit Downloads"
    case mitUngespielten = "Nur mit Ungespielten"
    var id: String { rawValue }

    var label: String {
        switch self {
        case .alle: return String(localized: "All")
        case .mitDownloads: return String(localized: "With Downloads")
        case .mitUngespielten: return String(localized: "With Unplayed")
        }
    }
}

/// Music album-grid sort. Resolved SERVER-side via getAlbumList2 (no direction
/// toggle; the API has no direction). The shelves stay fixed; only the grid
/// re-queries. `shelf` is the neutral shelf mapping used by the live music
/// source wiring. A future provider (Jellyfin) maps the same semantic cases or
/// reports a case as unavailable so the menu hides it.
nonisolated enum MusicSortOption: String, CaseIterable, Identifiable {
    case nameAZ = "Name A-Z"
    case kuenstler = "Künstler"
    case neu = "Neu"
    case zuletztGespielt = "Zuletzt gespielt"
    case meistgespielt = "Meistgespielt"
    var id: String { rawValue }

    var label: String {
        switch self {
        case .nameAZ: return String(localized: "Name A–Z")
        case .kuenstler: return String(localized: "Artist")
        case .neu: return String(localized: "Recently Added")
        case .zuletztGespielt: return String(localized: "Recently Played")
        case .meistgespielt: return String(localized: "Most Played")
        }
    }

    /// The neutral shelf this sort corresponds to. Providers translate it
    /// into their own vocabulary (no getAlbumList2 strings here anymore).
    var shelf: MusicShelf {
        switch self {
        case .nameAZ: return .alphabetical
        case .kuenstler: return .byArtist
        case .neu: return .newest
        case .zuletztGespielt: return .recent
        case .meistgespielt: return .frequent
        }
    }
}
