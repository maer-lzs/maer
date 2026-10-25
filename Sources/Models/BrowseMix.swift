// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation

/// The Browse double row on Start: three shares (the recommendations, the
/// free music, the free audiobooks and radio plays) mixed rank by rank.
/// The rule is pure so the row and its witnesses ask the same thing.
nonisolated enum BrowseMix {
    enum Share: String, CaseIterable, Sendable {
        case recommended, music, books
    }

    /// Rank by rank: the first of every share, then the second, and so
    /// on. An empty share falls away by itself; a share switched off is
    /// handed in empty. The limit caps the row, the page holds the rest.
    static func interleave<T>(_ shares: [[T]], limit: Int) -> [T] {
        var mixed: [T] = []
        let longest = shares.map(\.count).max() ?? 0
        for rank in 0..<longest {
            for share in shares where rank < share.count {
                guard mixed.count < limit else { return mixed }
                mixed.append(share[rank])
            }
        }
        return mixed
    }

    /// The double row's columns: two tiles each, filled top then bottom,
    /// so the mix reads down each column and on to the next.
    static func columns<T>(_ tiles: [T]) -> [[T]] {
        stride(from: 0, to: tiles.count, by: 2).map { Array(tiles[$0..<min($0 + 2, tiles.count)]) }
    }

    /// Whether the row marks each tile with its kind: only where it holds
    /// more than one kind. A row of one kind (a tab's lanes, a Start row
    /// with one share left) says nothing a glyph would add. A tile of no
    /// known kind does not count.
    static func marksKinds<Kind: Hashable>(_ kinds: [Kind?]) -> Bool {
        Set(kinds.compactMap { $0 }).count > 1
    }

    /// Why a share that is switched on stands empty on Start, for the log
    /// line. nil while it is off or has tiles.
    static func dropReason(_ share: Share, enabled: Bool, isEmpty: Bool, failure: String?) -> String? {
        guard enabled, isEmpty else { return nil }
        return "\(share.rawValue): \(failure ?? "no tiles")"
    }
}

/// The sections of the Browse page: every foreign catalog and directory
/// the app browses, each pointing at its existing page. The radio catalog
/// is not part of it (it has its own tab).
nonisolated enum BrowseSection: String, CaseIterable, Identifiable, Sendable {
    case recommendations, charts
    case classical, netlabels, oldRecords, jamendo
    case librivox, gutenberg, archiveBooks, oldTimeRadio, publicFeeds, independentFeeds

    enum Group: String, CaseIterable, Identifiable, Sendable {
        case podcasts, music, books
        var id: String { rawValue }
    }

    var id: String { rawValue }

    /// The area a section belongs to. The feeds of public broadcasters and
    /// independent studios are shows to subscribe to, so they stand with
    /// the podcasts.
    var group: Group {
        switch self {
        case .recommendations, .charts, .publicFeeds, .independentFeeds: .podcasts
        case .classical, .netlabels, .oldRecords, .jamendo: .music
        case .librivox, .gutenberg, .archiveBooks, .oldTimeRadio: .books
        }
    }

    /// The foreign sources the section's page asks. Empty for the curated
    /// feeds: they are content the app names, always shown.
    var sourceKeys: [String] {
        switch self {
        case .recommendations: ["appleCatalog", "podcastIndex"]
        case .charts: ["appleCatalog"]
        case .classical, .netlabels, .oldRecords, .archiveBooks, .oldTimeRadio: ["internetArchive"]
        case .jamendo: ["jamendo"]
        case .librivox: ["librivox"]
        case .gutenberg: ["gutenberg"]
        case .publicFeeds, .independentFeeds: []
        }
    }

    /// The sections shown: those whose page may ask any of its sources,
    /// the same question the pages themselves ask.
    static func shown(isAllowed: (String) -> Bool) -> [BrowseSection] {
        allCases.filter { $0.sourceKeys.isEmpty || $0.sourceKeys.contains(where: isAllowed) }
    }

    /// The sections of one area, or every section without one (Start).
    static func shown(in area: Group?, isAllowed: (String) -> Bool) -> [BrowseSection] {
        shown(isAllowed: isAllowed).filter { area == nil || $0.group == area }
    }
}

/// The Browse offer of a media tab: which area of the Browse page it
/// carries, and in which form. Without a server of the area the tab shows
/// the area's sections under "From open catalogs"; with one they fold into
/// the one Browse row under the own library. Radio has its own catalog,
/// Start mixes every area.
nonisolated enum TabBrowse {
    enum Form: Equatable, Sendable {
        /// The area's sections, each with its tiles.
        case sections
        /// The one Browse row, its lanes interleaved.
        case row
    }

    static func area(for tab: MediaType) -> BrowseSection.Group? {
        switch tab {
        case .audiobooks: .books
        case .music: .music
        case .podcasts: .podcasts
        case .home, .radio: nil
        }
    }

    /// The server of the area: Audiobookshelf for books, a music server for
    /// music, an Audiobookshelf podcast library for podcasts.
    static func hasServer(for tab: MediaType, absSignedIn: Bool,
                          musicServer: Bool, absPodcasts: Bool) -> Bool {
        switch tab {
        case .audiobooks: absSignedIn
        case .music: musicServer
        case .podcasts: absSignedIn && absPodcasts
        case .home, .radio: false
        }
    }

    static func form(hasServer: Bool) -> Form {
        hasServer ? .row : .sections
    }
}
