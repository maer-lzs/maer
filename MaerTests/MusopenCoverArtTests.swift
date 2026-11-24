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
    /// Composers of the stock (55 counted on 23.11.2026), their names as the
    /// source writes them; Beethoven was violet on violet before.
    static let composers = [
        "Ludwig van Beethoven", "Johann Sebastian Bach", "Wolfgang Amadeus Mozart", "Frédéric Chopin",
        "Johannes Brahms", "Franz Schubert", "Antonín Dvořák", "Pyotr Ilyich Tchaikovsky", "Giuseppe Verdi",
        "Felix Mendelssohn", "Robert Schumann", "Franz Liszt", "Claude Debussy", "Edvard Grieg", "Joseph Haydn",
        "George Frideric Handel", "Antonio Vivaldi", "Erik Satie", "Sergei Rachmaninoff", "Modest Mussorgsky",
        "Richard Wagner", "Gioachino Rossini", "Giacomo Puccini", "Georges Bizet", "Camille Saint-Saëns",
        "Maurice Ravel", "Edward Elgar", "Gustav Holst", "Johann Strauss II", "Johann Pachelbel", "Isaac Albeniz",
        "Gabriel Fauré", "Bedřich Smetana", "Jean Sibelius", "Gustav Mahler", "Anton Bruckner", "Hector Berlioz",
        "Carl Maria von Weber", "Niccolò Paganini", "Domenico Scarlatti", "Arcangelo Corelli", "Henry Purcell",
        "Georg Philipp Telemann", "Christoph Willibald Gluck", "Luigi Boccherini", "Muzio Clementi",
        "Nikolai Rimsky-Korsakov", "Alexander Borodin", "Enrique Granados", "Manuel de Falla", "Scott Joplin",
        "Gaetano Donizetti", "Vincenzo Bellini", "Jacques Offenbach", "Charles Gounod",
    ]

    @Test("a composer has one place of Goethe's circle and one cover, the same on every device and in every spelling")
    func onePlacePerComposer() {
        let mozart = MusopenCoverArt.art(composer: "Wolfgang Amadeus Mozart")
        // The source names one composer in several ways; the family name decides.
        for spelling in ["Mozart", "Mozart, Wolfgang Amadeus", "  wolfgang amadeus MOZART "] {
            #expect(MusopenCoverArt.art(composer: spelling) == mozart, "\(spelling)")
        }
        #expect(MusopenCoverArt.art(composer: nil) == MusopenCoverArt.art(composer: ""))
        #expect(MusopenCoverArt.goethePairs.count == 3)
        // Each pair stands roughly opposite on the circle.
        for pair in MusopenCoverArt.goethePairs {
            let apart = abs(pair.first - pair.second).truncatingRemainder(dividingBy: 360)
            #expect(min(apart, 360 - apart) >= 150, "\(pair)")
        }
        // The rule's place is the one its hue names (`GoetheCircleTests`).
        for name in Self.composers {
            let art = MusopenCoverArt.art(composer: name)
            #expect(GoetheCircleTests.place(ofHue: art.start[2]) == art.place, "\(name)")
            #expect(MusopenCoverArt.hue(place: art.place) == art.start[2])
        }
    }

    @Test("the two ends of every composer and of every place stand apart, the diagonal does not pass through grey, the text keeps 4.5:1")
    func colourRules() {
        for name in Self.composers + GoetheCircleTests.representatives.values.sorted() + ["", "x"] {
            let art = MusopenCoverArt.art(composer: name)
            let start = art.stops.first!, end = art.stops.last!
            #expect(MusopenCoverArt.distance(start, end) >= 0.18, "\(name): the two colours lie too close")
            #expect(abs(art.start[0] - art.end[0]) >= MusopenCoverArt.lightnessStep - 0.001, "\(name)")
            // Round the circle: every stop keeps colour, none is grey.
            for stop in art.stops {
                let lab = MusopenCoverArt.oklab(rgb: stop)
                #expect(sqrt(lab[1] * lab[1] + lab[2] * lab[2]) >= 0.04, "\(name): a stop is grey \(stop)")
            }
            // The text over the first half of the diagonal.
            let text = art.darkText ? MusopenCoverArt.darkText : [1, 1, 1]
            for stop in art.stops.prefix(art.stops.count / 2 + 1) {
                #expect(MusopenCoverArt.contrast(text, stop) >= 4.5, "\(name): text \(art.darkText ? "dark" : "white") on \(stop)")
            }
        }
        // The instrument: opposites of one lightness are far apart, a colour from itself not at all.
        #expect(MusopenCoverArt.distance([0.5, 0.2, 0.5], [0.5, 0.2, 0.5]) < 0.0001)
        #expect(MusopenCoverArt.contrast([1, 1, 1], [0, 0, 0]) > 20)
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
        #expect(cover.contains("LinearGradient(colors: art.stops.map(colour), startPoint: .topLeading, endPoint: .bottomTrailing)"),
                "the cover draws no diagonal round the colour circle")
        #expect(cover.contains(".foregroundStyle(art.darkText ? colour(MusopenCoverArt.darkText) : .white)"),
                "the text does not follow the lightness under it")
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
