// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// A release of archive.org opened as music offers no chain, also before
/// anything of it was played; the same page as a reading does.
struct ChapterChainAlbumTests {
    @Test("the page of an archive.org release as an album offers no chain, as a work in parts it does")
    func anAlbumOffersNoChain() {
        #expect(!ArchiveSeriesPage.offersChain(.album), "a music release offered to go in chapter by chapter")
        #expect(ArchiveSeriesPage.offersChain(.series))
    }

    @Test("the page hands its player to the chain only by its form", .needsTheSources)
    func thePageAsksItsForm() throws {
        let page = SyncContractFenceTests.stripped(
            try String(contentsOf: SourceTree.root.appendingPathComponent("Sources/Views/CatalogSourcePage.swift"),
                       encoding: .utf8))
        let body = try #require(ABSPodcastRefreshTests.body(of: "struct ArchiveSeriesPage", in: page))
        #expect(body.contains("Self.offersChain(effectiveFlavor) ? playerCoordinator : nil"),
                "the page offers the chain without asking its form")
    }
}
#endif
