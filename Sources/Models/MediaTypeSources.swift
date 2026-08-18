// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation

/// Which sources feed a media type — the answer to "what speaks into this tab",
/// as data rather than as a layout.
///
/// The finding behind it: the podcast tab's settings lived almost entirely
/// under "Sources", so answering "how do my podcasts behave" meant leaving the
/// place that is about podcasts. A media-type pill can only become the complete
/// entry point of its type if it can NAME its sources — and it must name them
/// exactly as the source register does, so that one account appearing under two
/// types is recognisably the SAME account and not a copy.
nonisolated struct MediaTypeSource: Equatable, Identifiable, Sendable {
    /// Stable key — also the accessibility identifier's stem, so a probe can
    /// address the row without knowing the display language.
    let id: String
    /// The account/source name. Deliberately the same string in every place it
    /// appears: recognisability is the point.
    let title: String
    let symbol: String
    /// An account is reached at ONE page; several types link to that same page.
    let needsAccount: Bool

    var accessibilityId: String { "media-source-\(id)" }
}

nonisolated enum MediaTypeSources {

    /// The sources of an area, in the order they are offered. Account-bound
    /// ones first (they answer "where does my stuff come from"), the
    /// account-less ones after — they always work and never need attention.
    static func all(for area: SourceMapArea) -> [MediaTypeSource] {
        switch area {
        case .audiobooks:
            return [
                MediaTypeSource(id: "abs", title: "Audiobookshelf",
                                symbol: "server.rack", needsAccount: true),
                MediaTypeSource(id: "local-files", title: "Local Files",
                                symbol: "folder", needsAccount: false),
            ]
        case .music:
            return [
                MediaTypeSource(id: "subsonic", title: "Subsonic",
                                symbol: "music.note", needsAccount: true),
                MediaTypeSource(id: "jellyfin", title: "Jellyfin",
                                symbol: "music.note.house", needsAccount: true),
            ]
        case .podcasts:
            return [
                MediaTypeSource(id: "abs", title: "Audiobookshelf",
                                symbol: "server.rack", needsAccount: true),
                MediaTypeSource(id: "gpodder", title: "gpodder",
                                symbol: "arrow.triangle.2.circlepath", needsAccount: true),
                MediaTypeSource(id: "pinchflat", title: "Pinchflat",
                                symbol: "play.rectangle", needsAccount: true),
                MediaTypeSource(id: "rss", title: "RSS feeds",
                                symbol: "dot.radiowaves.up.forward", needsAccount: false),
            ]
        case .radio:
            return [
                MediaTypeSource(id: "radio-browser", title: "Radio Browser",
                                symbol: "dot.radiowaves.left.and.right", needsAccount: false),
            ]
        case .freeCatalogs:
            return [
                MediaTypeSource(id: "free-catalogs", title: "Free Catalogs",
                                symbol: "books.vertical", needsAccount: false),
            ]
        }
    }

    /// The areas ONE account serves. The recognisability rule from the other
    /// side: Audiobookshelf is the same account under Audiobooks and under
    /// Podcasts, and both must lead to the same page.
    static func areas(servedBy sourceId: String) -> [SourceMapArea] {
        SourceMapArea.allCases.filter { area in
            all(for: area).contains { $0.id == sourceId }
        }
    }
}
