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
    @Test("a composer has one colour, the same on every device and in every spelling the source uses: the family name decides")
    func oneColourPerComposer() {
        #expect(MusopenCoverArt.colourIndex(composer: "Wolfgang Amadeus Mozart") == 10)
        // The source names one composer in several ways.
        #expect(MusopenCoverArt.colourIndex(composer: "Mozart") == 10)
        #expect(MusopenCoverArt.colourIndex(composer: "Mozart, Wolfgang Amadeus") == 10)
        #expect(MusopenCoverArt.colourIndex(composer: "  wolfgang amadeus MOZART ") == 10)
        #expect(MusopenCoverArt.colourIndex(composer: "Ludwig van Beethoven") == 9)
        #expect(MusopenCoverArt.colourIndex(composer: "Franz Schubert") == 11)
        #expect(MusopenCoverArt.colourIndex(composer: "Antonín Dvořák") == 7)
        #expect(MusopenCoverArt.colourIndex(composer: "Johannes Brahms") == 8)
        #expect(MusopenCoverArt.palette.indices.contains(8)
                && MusopenCoverArt.colour(composer: "Johannes Brahms") == MusopenCoverArt.palette[8])
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

    @Test("two colours per composer from the same hash, never the same one, the same for every spelling")
    func twoColours() {
        #expect(MusopenCoverArt.colourIndices(composer: "Mozart") == (start: 10, end: 4))
        #expect(MusopenCoverArt.colourIndices(composer: "Wolfgang Amadeus Mozart") == (start: 10, end: 4))
        #expect(MusopenCoverArt.colourIndices(composer: "Frédéric Chopin") == (start: 10, end: 1))
        #expect(MusopenCoverArt.colourIndices(composer: "Johannes Brahms") == (start: 8, end: 6))
        for name in ["Bach", "Haydn", "Grieg", "Smetana", "", "x"] {
            let pair = MusopenCoverArt.colourIndices(composer: name)
            #expect(pair.start != pair.end, "\(name)")
            #expect(pair.start == MusopenCoverArt.colourIndex(composer: name))
        }
    }

    @Test("white text reaches 4.5:1 everywhere along every pair's diagonal, under the letter as well")
    func contrastAlongTheGradient() {
        let palette = MusopenCoverArt.palette
        for (i, start) in palette.enumerated() {
            for (j, end) in palette.enumerated() where i != j {
                for step in 0...10 {
                    let rgb = MusopenCoverArt.mix(start, end, at: Double(step) / 10)
                    for shown in [rgb, MusopenCoverArt.underLetter(rgb)] {
                        #expect(TextContrast.againstWhite(red: shown[0], green: shown[1], blue: shown[2]) >= 4.5,
                                "\(i) to \(j) at \(step)")
                    }
                }
            }
        }
        #expect(MusopenCoverArt.mix([0, 0, 0], [1, 1, 1], at: 0.5) == [0.5, 0.5, 0.5])
        #expect(MusopenCoverArt.letterOpacity > 0.1 && MusopenCoverArt.letterOpacity < 0.5, "the letter is no shade")
    }

    @Test("the initial is the family name's first letter, else the work's")
    func initial() {
        #expect(MusopenCoverArt.initial(composer: "Wolfgang Amadeus Mozart", title: "1st violin B 02") == "M")
        #expect(MusopenCoverArt.initial(composer: "Frédéric Chopin", title: "x") == "C")
        #expect(MusopenCoverArt.initial(composer: "dvořák", title: "x") == "D")
        #expect(MusopenCoverArt.initial(composer: nil, title: "nocturne") == "N")
        #expect(MusopenCoverArt.initial(composer: "  ", title: "") == "")
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

    @Test("the drawn cover is drawn in one place and comes by its address everywhere; its text fits the picture", .needsTheSources)
    func oneCover() throws {
        func source(_ path: String) throws -> String {
            SyncContractFenceTests.stripped(
                try String(contentsOf: SourceTree.root.appendingPathComponent(path), encoding: .utf8))
        }
        let cover = try source("Sources/Views/Music/MusopenViews.swift")
        #expect(cover.contains("struct MusopenCover: View"))
        #expect(cover.contains(".minimumScaleFactor("), "the cover's text breaks off instead of fitting")
        #expect(cover.contains("LinearGradient(colors: [colour(art.start), colour(art.end)], startPoint: .topLeading, endPoint: .bottomTrailing)"),
                "the cover draws no diagonal of its two colours")
        #expect(cover.contains("MusopenCoverArt.initial(composer: lines.composer, title: lines.work)"),
                "the cover carries no initial")
        // One place draws it: the renderer behind the drawn address. No view
        // decides by itself which recording gets the drawing.
        var drawers: [String] = []
        for file in ProjectFileIntegrityTests.sourceFiles() {
            let text = SyncContractFenceTests.stripped(try SourceTree.text(file))
            let count = text.components(separatedBy: "MusopenCover(").count - 1
            if count > 0 { drawers.append("\(file.lastPathComponent): \(count)") }
        }
        #expect(drawers == ["MusopenViews.swift: 1"], "a view draws the cover itself: \(drawers)")
        #expect(cover.contains("ImageRenderer(content: MusopenCover(title: parts.title, composer: parts.composer)"))
        #expect(try source("Sources/Networking/Artwork.swift").contains("guard let data = DrawnCoverRenderer.png(for: url)"),
                "the door of the covers does not draw a drawn address")
        #expect(try source("Sources/Providers/FreeCatalogProvider.swift")
            .contains("return DrawnCover.url(title: meta.title ?? \"\", composer: meta.authorName)"),
                "a recording's cover address is not the drawn one")
    }
}
#endif
