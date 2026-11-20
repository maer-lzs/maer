// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation

/// Browsing the catalogues shows only titles with a cover. A title shows
/// when its source names a cover address and that address has not answered
/// "none here" (`AbsentCovers`). The rule acts where a page or shelf is
/// built, never in a tile, and never in the search.
nonisolated enum CatalogCoverRule {
    /// How long "none here" holds: archive.org often makes a picture later,
    /// and a title must not leave the browsing for good.
    static let absentFor: Double = 30 * 24 * 3600

    static func shows(coverURL: URL?, isAbsent: (URL) -> Bool) -> Bool {
        guard let coverURL else { return false }
        return !isAbsent(coverURL)
    }

    /// Whether "none here", noted at `since`, still holds at `now`.
    static func stillAbsent(since: Double, now: Double) -> Bool {
        now - since < absentFor
    }

    /// The cover addresses the catalogues name (`FreeCatalogProvider.coverURL`):
    /// archive.org's image service, Gutenberg's covers, Jamendo's pictures.
    static func isCatalogCover(_ url: URL) -> Bool {
        switch url.host {
        case "archive.org": return url.path.hasPrefix("/services/img/")
        case "www.gutenberg.org", "gutenberg.org": return url.path.hasPrefix("/cache/epub/")
        case "usercontent.jamendo.com": return true
        default: return false
        }
    }
}
