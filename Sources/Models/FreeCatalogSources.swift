// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation

/// THE source list of the merged catalog page ("Freie Hörbücher &
/// Hörspiele"). One row per source, each row a preview of its own page.
///
/// The split into feed-based and catalog-based sources is the distribution
/// rule: the podcast tab previews the FEED sources (they land
/// there as subscriptions), the audiobooks tab previews the CATALOG sources
/// (they land in the audiobook corner). The condition "no tile appears
/// in both tabs" holds structurally because the two sets are disjoint.
/// Guaranteed by this being ONE enum, tested.
nonisolated enum CatalogSource: String, CaseIterable, Identifiable, Sendable {
    // Feed-based (action: subscribe). Rows of MediaRowContent.
    case oerr
    /// X²·1: the FUSED independent row (formerly escapeArtists + usIndies).
    /// Anthologies, series and readings, English AND German (the language
    /// bracket was dropped; language logic mixes).
    case independents
    // Catalog-based (action: play / take over). Tile rows.
    case oldTimeRadio
    case librivox
    case archiveBooks
    case gutenberg

    var id: String { rawValue }

    /// The split: what lands as a subscription previews in the podcast
    /// tab; what lands in the audiobook corner previews in the audiobooks tab.
    var isFeedBased: Bool {
        switch self {
        case .oerr, .independents: return true
        case .oldTimeRadio, .librivox, .archiveBooks, .gutenberg: return false
        }
    }

    /// May this row's foreign service be asked? The feed-based rows are
    /// curated CONTENT (the app fetches what the list names, no directory),
    /// so they hang on no source switch; the catalog rows ask theirs.
    var isAllowed: Bool {
        switch self {
        case .oerr, .independents: return true
        case .librivox: return AppStorageKeys.librivoxActive
        case .gutenberg: return AppStorageKeys.gutenbergSourceActive
        case .archiveBooks, .oldTimeRadio: return AppStorageKeys.archiveBooksActive
        }
    }

    /// The row/page title: every section names its SOURCE. No
    /// leftovers-bin titles.
    /// The majority-standard line of a MIXED source: stated once at the
    /// top of its pages, and the tiles then carry only DEVIATIONS (a
    /// stated licence, a computed public domain). Old-time radio is the
    /// one mixed source: about a third carries real CC licences, the
    /// majority states nothing. nil = the tiles keep saying it per item.
    /// The music areas keep their own flag with the standing red probe
    /// (netlabels never hide).
    var majorityRightsNote: String? {
        guard self == .oldTimeRadio else { return nil }
        return String(localized: "Most of these recordings state no rights information; tiles only show deviations (licences, computed public domain).")
    }

    var title: String {
        switch self {
        case .oerr:          String(localized: "Public Broadcast Radio Plays")
        // X²·1/X²·2: ONE fused row; the language bracket fell (German
        // community entries joined, the preview mixes active languages).
        case .independents:  String(localized: "Independent Stories & Anthologies")
        case .oldTimeRadio:  "Old Time Radio"
        case .librivox:      "LibriVox"
        // The title names the CONTENT, the sender sits in the
        // parenthesis. One string for row AND source page.
        case .archiveBooks:  String(localized: "Audiobooks (Internet Archive)")
        case .gutenberg:     "Project Gutenberg"
        }
    }

    /// The curated feeds of a FEED source (empty for catalog sources).
    /// PURE seed data. This layer stays Foundation-only;
    /// the LIVE OERR enrichment is a provider concern, and the UI reaches it
    /// through `OERRLiveStore.feeds(for:languages:)`. The dependency points
    /// from the store to this data, never back.
    func curatedFeeds(forLanguages codes: [String]) -> [HoerspielCuration.Entry] {
        guard isFeedBased else { return [] }
        return HoerspielCuration.feeds(forLanguages: codes).filter { entry in
            switch self {
            case .oerr:         entry.group == .oerr
            case .independents: entry.group == .independent
            default:            false
            }
        }
    }
}
