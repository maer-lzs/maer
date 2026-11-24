// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Foundation
import Testing
import UIKit
@testable import Maer

/// Goethe's circle with 24 places: a composer has one place for good, the
/// other end of his cover is the place opposite (+12). The six anchors are
/// the hues of Goethe's three pairs, four places apart in the order of the
/// circle; the three places between two anchors lie evenly between their
/// hues, in the same direction. So every composer has practically a pair of
/// his own, twelve pairs instead of three.
@MainActor
struct GoetheCircleTests {
    /// The anchors in the order of the circle with their place: yellow 100
    /// (0), orange 55 (4), purple 350 (8), violet 305 (12), blue 260 (16),
    /// green 145 (20). Written out, so the witness does not read the rule it
    /// checks.
    nonisolated static let anchors: [Double] = [100, 55, 350, 305, 260, 145]

    /// The hue of a place, derived from the anchors: the way between two
    /// anchors in the direction of the circle (falling hue), in four even steps.
    nonisolated static func expectedHue(place: Int) -> Double {
        let place = ((place % 24) + 24) % 24
        let from = anchors[place / 4], to = anchors[(place / 4 + 1) % 6]
        var fall = (from - to).truncatingRemainder(dividingBy: 360)
        if fall <= 0 { fall += 360 }
        let hue = (from - fall * Double(place % 4) / 4).truncatingRemainder(dividingBy: 360)
        return hue < 0 ? hue + 360 : hue
    }

    nonisolated static func place(ofHue hue: Double) -> Int? {
        (0..<24).first { abs(expectedHue(place: $0) - hue) < 0.000_1 }
    }

    /// The place of a composer, read from the hue of his cover's first end.
    nonisolated static func place(of name: String) -> Int? {
        place(ofHue: MusopenCoverArt.art(composer: name).start[2])
    }

    /// One name for each place the rule reaches, the first of a fixed row of
    /// made up names that lands there: so every place is drawn and checked.
    nonisolated static let representatives: [Int: String] = {
        var found: [Int: String] = [:]
        for index in 0..<2000 where found.count < 24 {
            let name = "Komponist\(index)"
            if let place = place(of: name), found[place] == nil { found[place] = name }
        }
        return found
    }()

    @Test("the anchors are Goethe's three pairs, and the hues fall evenly from anchor to anchor without passing one")
    func theCircle() {
        // The three pairs opposite each other, as Goethe paired them, in today's hues.
        let pairs = Set((0..<3).map { [Self.anchors[$0], Self.anchors[$0 + 3]].sorted() })
        let today = Set(MusopenCoverArt.goethePairs.map { [$0.first, $0.second].sorted() })
        #expect(pairs == today)
        var total = 0.0
        for place in 0..<24 {
            var step = (Self.expectedHue(place: place) - Self.expectedHue(place: place + 1)).truncatingRemainder(dividingBy: 360)
            if step < 0 { step += 360 }
            #expect(step > 0, "place \(place): the hue does not fall")
            total += step
        }
        #expect(abs(total - 360) < 0.000_1, "the way round passes an anchor: \(total)")
        for (index, anchor) in Self.anchors.enumerated() { #expect(Self.expectedHue(place: index * 4) == anchor) }
    }

    @Test("every place of the 24 is reached, and the other end is the place opposite")
    func twentyFourPlacesOppositeEnds() {
        #expect(Self.representatives.count == 24, "reached: \(Self.representatives.keys.sorted())")
        for name in MusopenCoverArtTests.composers + Array(Self.representatives.values) {
            let art = MusopenCoverArt.art(composer: name)
            let place = Self.place(ofHue: art.start[2])
            #expect(place != nil, "\(name): the first end \(art.start[2]) is no place of the circle")
            guard let place else { continue }
            #expect(abs(art.end[2] - Self.expectedHue(place: place + 12)) < 0.000_1,
                    "\(name): the other end \(art.end[2]) is not opposite place \(place)")
        }
    }

    /// The bound of the spread: with 55 names hashed evenly onto 24 places
    /// one place holds X ~ Binomial(55, 1/24) names, 2.29 on average. The
    /// bound is the smallest k with 24 · P(X ≥ k) below 5 percent: so the
    /// rule fails the witness only when a place gets more than even hashing
    /// gives one time in twenty.
    nonisolated static func spreadBound(names: Int, places: Int) -> Int {
        let p = 1 / Double(places)
        func atLeast(_ k: Int) -> Double {
            (k...names).reduce(0.0) { sum, i in
                sum + exp(lgamma(Double(names + 1)) - lgamma(Double(i + 1)) - lgamma(Double(names - i + 1))
                    + Double(i) * log(p) + Double(names - i) * log(1 - p))
            }
        }
        return (1...names).first { Double(places) * atLeast($0) < 0.05 } ?? names
    }

    @Test("the composers of the stock spread over the places, none takes more than even hashing allows, Beethoven keeps his")
    func spread() {
        let names = MusopenCoverArtTests.composers
        let bound = Self.spreadBound(names: names.count, places: 24)
        #expect(bound == 8, "the derivation moved: \(bound)")
        var count: [Int: Int] = [:]
        for name in names { if let place = Self.place(of: name) { count[place, default: 0] += 1 } }
        let fullest = count.values.max() ?? 0
        #expect(fullest < bound, "a place holds \(fullest) of \(names.count) composers: \(count.sorted { $0.key < $1.key })")
        let beethoven = Self.place(of: "Ludwig van Beethoven")
        #expect(beethoven != nil && beethoven == Self.place(of: "Beethoven"))
        #expect(MusopenCoverArt.art(composer: "Ludwig van Beethoven") == MusopenCoverArt.art(composer: "Ludwig van Beethoven"))
    }

    /// The colour of one pixel of a picture as sRGB, 0 to 1.
    private func pixel(_ image: UIImage, x: Int, y: Int) -> [Double] {
        guard let cg = image.cgImage, let data = cg.dataProvider?.data, let bytes = CFDataGetBytePtr(data) else { return [] }
        let offset = y * cg.bytesPerRow + x * (cg.bitsPerPixel / 8)
        return (0..<3).map { Double(bytes[offset + $0]) / 255 }
    }

    @Test("on the rendered picture of every place the two corners stand apart, and the text keeps 4.5:1 over its half")
    func everyPlaceRendered() throws {
        #expect(Self.representatives.count == 24)
        let side = Int(DrawnCoverRenderer.side)
        for (place, name) in Self.representatives.sorted(by: { $0.key < $1.key }) {
            let data = try #require(DrawnCoverRenderer.png(for: DrawnCover.url(title: "", composer: name)))
            let image = try #require(UIImage(data: data))
            let near = pixel(image, x: 4, y: 4), far = pixel(image, x: side - 5, y: side - 5)
            guard near.count == 3, far.count == 3 else { Issue.record("place \(place): no pixels read"); continue }
            #expect(MusopenCoverArt.distance(near, far) >= 0.15, "place \(place): \(near) against \(far)")
            let art = MusopenCoverArt.art(composer: name)
            let text = art.darkText ? MusopenCoverArt.darkText : [1, 1, 1]
            for stop in art.stops.prefix(art.stops.count / 2 + 1) {
                #expect(MusopenCoverArt.contrast(text, stop) >= 4.5, "place \(place): text on \(stop)")
            }
        }
    }
}
#endif
