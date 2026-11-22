// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Foundation
import Testing
@testable import Maer

/// The drawn cover of a Musopen recording: a field whose colour belongs to
/// the composer, the same on every device, with the composer and the work
/// large on it in white. A recording without a composer shows its work.
/// The tile, the page and the player draw the same cover.
struct MusopenCoverArtTests {
    @Test("a composer has one colour, the same on every device and in every spelling of case and space")
    func oneColourPerComposer() {
        #expect(MusopenCoverArt.colourIndex(composer: "Wolfgang Amadeus Mozart") == 7)
        #expect(MusopenCoverArt.colourIndex(composer: "Ludwig van Beethoven") == 4)
        #expect(MusopenCoverArt.colourIndex(composer: "Frédéric Chopin") == 10)
        #expect(MusopenCoverArt.colourIndex(composer: "Franz Schubert") == 2)
        #expect(MusopenCoverArt.colourIndex(composer: "  wolfgang amadeus MOZART ") == 7)
        #expect(MusopenCoverArt.colourIndex(composer: "Johannes Brahms") == 6)
        #expect(MusopenCoverArt.palette.indices.contains(6)
                && MusopenCoverArt.colour(composer: "Johannes Brahms") == MusopenCoverArt.palette[6])
        #expect(MusopenCoverArt.colourIndex(composer: nil) == 0)
        #expect(MusopenCoverArt.colourIndex(composer: "") == 0)
    }

    @Test("twelve colours, white text reaches 4.5:1 on each")
    func palette() {
        #expect(MusopenCoverArt.palette.count == 12)
        for rgb in MusopenCoverArt.palette {
            #expect(TextContrast.againstWhite(red: rgb[0], green: rgb[1], blue: rgb[2]) >= 4.5, "\(rgb)")
        }
    }

    @Test("the composer above the work; without a composer the work alone")
    func lines() {
        let both = MusopenCoverArt.lines(title: "1st violin B 02", composer: "Wolfgang Amadeus Mozart")
        #expect(both.composer == "Wolfgang Amadeus Mozart")
        #expect(both.work == "1st violin B 02")
        let alone = MusopenCoverArt.lines(title: "Nocturne Op. 9 No. 2", composer: "  ")
        #expect(alone.composer == nil)
        #expect(alone.work == "Nocturne Op. 9 No. 2")
        #expect(MusopenCoverArt.applies(to: MusopenCatalog.prefix + "1"))
        #expect(!MusopenCoverArt.applies(to: FreeCatalog.archivePrefix + "x"))
    }

    @Test("the tile, the page and the player draw the one cover; its text fits the picture instead of breaking off", .needsTheSources)
    func oneCover() throws {
        func source(_ path: String) throws -> String {
            SyncContractFenceTests.stripped(
                try String(contentsOf: SourceTree.root.appendingPathComponent(path), encoding: .utf8))
        }
        let cover = try source("Sources/Views/Music/MusopenViews.swift")
        #expect(cover.contains("struct MusopenCover: View"))
        #expect(cover.contains(".minimumScaleFactor("), "the cover's text breaks off instead of fitting")
        #expect(try source("Sources/Views/FeedArtwork.swift").contains("MusopenCover(title: item.title, composer: item.author)"),
                "the catalogue tile draws no cover for a recording")
        #expect(try source("Sources/Views/CatalogSourcePage.swift").contains("MusopenCover(title:"),
                "the page shows another placeholder")
        #expect(try source("Sources/Views/PlayerView.swift").contains("MusopenCover(title:"),
                "the player shows another placeholder")
    }
}
#endif
