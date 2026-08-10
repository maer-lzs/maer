// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation

/// 11be262: THE source list of the merged catalog page ("Freie Hörbücher &
/// Hörspiele") — one row per source, each row a preview of its own page.
///
/// The split into feed-based and catalog-based sources is Paket 4's
/// distribution rule: the podcast tab previews the FEED sources (they land
/// there as subscriptions), the audiobooks tab previews the CATALOG sources
/// (they land in the audiobook corner). The condition "no tile appears
/// in both tabs" holds structurally because the two sets are disjoint —
/// guaranteed by this being ONE enum, tested.
nonisolated enum CatalogSource: String, CaseIterable, Identifiable, Sendable {
    // Feed-based (action: subscribe) — rows of MediaRowContent.
    case oerr
    /// X²·1: the FUSED independent row (formerly escapeArtists + usIndies) —
    /// anthologies, series and readings, English AND German (the language
    /// bracket was dropped; language logic mixes).
    case independents
    // Catalog-based (action: play / take over) — tile rows.
    case oldTimeRadio
    case librivox
    case archiveBooks
    case gutenberg

    var id: String { rawValue }

    /// Paket 4's split: what lands as a subscription previews in the podcast
    /// tab; what lands in the audiobook corner previews in the audiobooks tab.
    var isFeedBased: Bool {
        switch self {
        case .oerr, .independents: return true
        case .oldTimeRadio, .librivox, .archiveBooks, .gutenberg: return false
        }
    }

    /// Proper names stay verbatim (never translated); the descriptive ones
    /// are display text and localize.
    var isProperName: Bool {
        switch self {
        // "Old Time Radio" and "Internet Archive" are collection/institution
        // names — verbatim like the publishers (733ac2a: the collection name
        // is precise and recognisable).
        case .librivox, .gutenberg, .oldTimeRadio, .archiveBooks: return true
        // 9815608 D: "Escape Artists" is a PUBLISHER, not a content name —
        // the row title names the content, the publisher stays the sender
        // line on every tile (author field).
        case .oerr, .independents: return false
        }
    }

    /// The row/page title. 733ac2a: every section names its SOURCE — no
    /// leftovers-bin titles.
    var title: String {
        switch self {
        case .oerr:          String(localized: "Public Broadcast Radio Plays")
        // X²·1/X²·2: ONE fused row; the language bracket fell (German
        // community entries joined, the preview mixes active languages).
        case .independents:  String(localized: "Independent Stories & Anthologies")
        case .oldTimeRadio:  "Old Time Radio"
        case .librivox:      "LibriVox"
        // P3 (D2 rule): the title names the CONTENT, the sender sits in the
        // parenthesis — one string for row AND source page (fe13468).
        case .archiveBooks:  String(localized: "Audiobooks (Internet Archive)")
        case .gutenberg:     "Project Gutenberg"
        }
    }

    /// The curated feeds of a FEED source (empty for catalog sources) —
    /// PURE seed data. Befund Y (5a646f7): this layer stays Foundation-only;
    /// the LIVE OERR enrichment is a provider concern, and the UI reaches it
    /// through `OERRLiveStore.feeds(for:languages:)` — the dependency points
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
