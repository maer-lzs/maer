// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation

/// The two forms of a catalogue cover whose source keeps a larger one than
/// the grid shows. The grid and the rows ask the smaller address (a cover
/// of more than three times the bytes stays out of a grid cell); the large
/// views (a title's page, the full player, the lock screen) ask the larger
/// one (`large(_:)`). The image door falls back to the smaller address when
/// the larger one names no picture (`Artwork`), and the cover cache reads a
/// cover kept under the smaller name while nothing stands under the larger
/// (`ImageCache.formerName`). Pure, so the mapping is testable without the
/// network.
nonisolated enum CoverAddressHistory {
    /// The address a large view asks for `url`: its larger form where the
    /// source keeps one, else `url` itself.
    static func large(_ url: URL?) -> URL? {
        url.map { largerAddress(of: $0) ?? $0 }
    }

    /// The larger form of a grid cover, or nil when the source keeps none.
    static func largerAddress(of url: URL) -> URL? {
        // Gutenberg: cache/epub/<n>/pg<n>.cover.medium.jpg
        guard let parts = gutenbergCache(url), parts.count == 4,
              parts[3] == "pg\(parts[2]).cover.medium.jpg" else { return nil }
        return FreeCatalog.gutenbergScanURL(number: parts[2])
    }

    /// The smaller address a larger cover was asked as, or nil when it has
    /// none.
    static func formerAddress(of url: URL) -> URL? {
        // Gutenberg: cache/epub/<n>/images/cover.jpg
        guard let parts = gutenbergCache(url), parts.count == 5,
              parts[3] == "images", parts[4] == "cover.jpg" else { return nil }
        return FreeCatalog.gutenbergCoverURL(number: parts[2])
    }

    /// The path parts of an address under Gutenberg's `cache/epub/<n>/`, nil
    /// for any other address.
    private static func gutenbergCache(_ url: URL) -> [String]? {
        guard url.host == "www.gutenberg.org" else { return nil }
        let parts = url.path.split(separator: "/").map(String.init)
        guard parts.count >= 3, parts[0] == "cache", parts[1] == "epub" else { return nil }
        return parts
    }
}
