// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// The vertical preview grids on the tab roots end with the line that leads
/// to their full page, the same page as the chevron above. Measured on
/// 24.10.2026: two such grids, the audiobook tab's and the podcast tab's
/// subscriptions; the downloaded sections unfold in place, every other grid
/// is a page of its own.
struct PreviewGridShowAllTests {
    @Test("jedes senkrechte Vorschau-Raster der Reiter endet mit der Zeile zur Vollseite", .needsTheSources)
    func everyPreviewGridEndsWithItsLine() throws {
        let grids: [(file: String, section: String, destination: String)] = [
            ("Sources/Views/LibraryView.swift", "private var allBooksSection", "LibraryListRoute.allBooks"),
            ("Sources/Views/PodcastsView.swift", "private var recentlyUpdatedSection", "PodcastRoute.subscriptions"),
        ]
        // The one reader of a declaration's text, with its own red probe there.
        for grid in grids {
            let text = try EpochUnderLockTests.code(grid.file)
            let body = try #require(EpochUnderLockTests.body(of: grid.section, in: text), "\(grid.section) is gone")
            #expect(body.contains("ShowAllRow("), "\(grid.section) ends without the line to its page")
            #expect(body.contains("destination: \(grid.destination)"), "\(grid.section)'s line leads elsewhere")
        }
    }
}
#endif
