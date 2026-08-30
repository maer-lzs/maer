// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Testing
import Foundation
import UIKit
import SwiftUI
@testable import Maer

/// The "My Stations" row. Composition, the exclusion fence, and the
/// three-state line.
@Suite struct RadioMyStationsTests {

    private func station(_ id: String, _ name: String? = nil) -> RadioStation {
        RadioStation(id: "radio:rb:\(id)", name: name ?? id,
                     streamURL: "https://s.test/\(id)", homepage: "https://h.test")
    }

    /// The fence the order asks for: a stated preference outranks measured
    /// time. Otherwise the order is unexplainable to whoever set the star.
    @Test func aFavoriteWithoutTimeStandsBeforeANonFavoriteWithTime() {
        let fav = station("fav"), heavy = station("heavy")
        let row = RadioMyStations.composed(
            favorites: [fav], mostPlayed: [heavy],
            seconds: ["radio:rb:heavy": 99_999], excluding: nil, limit: 8)
        #expect(row.map(\.id) == ["radio:rb:fav", "radio:rb:heavy"])
    }

    @Test func withinEachGroupTheLongerListenedComesFirst() {
        let a = station("a"), b = station("b"), c = station("c")
        let row = RadioMyStations.composed(
            favorites: [a, b], mostPlayed: [c],
            seconds: ["radio:rb:a": 100, "radio:rb:b": 900, "radio:rb:c": 5],
            excluding: nil, limit: 8)
        #expect(row.map(\.id) == ["radio:rb:b", "radio:rb:a", "radio:rb:c"])
    }

    /// The second fence: the station of the row BELOW does not appear here.
    /// It is not gone. It stands one row lower.
    @Test func theStationOfTheRowBelowIsLeftOut() {
        let recent = station("recent"), other = station("other")
        let row = RadioMyStations.composed(
            favorites: [recent, other], mostPlayed: [],
            seconds: [:], excluding: "radio:rb:recent", limit: 8)
        #expect(row.map(\.id) == ["radio:rb:other"])
    }

    @Test func theExcludedStationIsTheOneTheRowBelowShows() {
        #expect(RadioMyStations.excludedID(recents: [station("x"), station("y")]) == "radio:rb:x")
        #expect(RadioMyStations.excludedID(recents: []) == nil)
    }

    /// A station in both sources is ONE card, not two.
    @Test func aFavoriteThatIsAlsoMostPlayedAppearsOnce() {
        let both = station("both")
        let row = RadioMyStations.composed(favorites: [both], mostPlayed: [both],
                                           seconds: [:], excluding: nil, limit: 8)
        #expect(row.count == 1)
    }

    /// KEIN Favorit verschwindet. Die Vollseite
    /// zeigt ALLE Favoriten des Stores, ungefiltert von Auslass-Regel und
    /// Deckelung. Store-Menge == Vollseiten-Menge ist die Zusicherung; damit
    /// ist jeder markierte Favorit in hoechstens zwei Tipps erreichbar, den
    /// Auslass-Fall eingeschlossen.
    @Test func theFullPageShowsEveryFavoriteUnfiltered() {
        let favorites = (0..<7).map { station("fav\($0)") }
        // Exactly the full page's call: no exclusion, no cap.
        let page = RadioMyStations.composed(favorites: favorites, mostPlayed: [],
                                            seconds: [:], excluding: nil, limit: .max)
        #expect(Set(page.map(\.id)) == Set(favorites.map(\.id)),
                "die Vollseite muss die Store-Menge zeigen — ungefiltert")
    }

    @Test func theRowIsCapped() {
        let many = (0..<20).map { station("s\($0)") }
        #expect(RadioMyStations.composed(favorites: many, mostPlayed: [],
                                         seconds: [:], excluding: nil, limit: 8).count == 8)
    }

    // MARK: - The one line, three states

    @Test func aRunningStationShowsItsShow() {
        #expect(RadioMyStations.cardLine(isRunning: true, runningLine: "Wer weiß denn sowas",
                                         seconds: 99_999) == .running("Wer weiß denn sowas"))
    }

    /// The floor is an honesty rule, not decoration: below it we say nothing.
    @Test func belowAnHourTheLineStaysSilent() {
        #expect(RadioMyStations.cardLine(isRunning: false, runningLine: nil, seconds: 3599) == .none)
        #expect(RadioMyStations.cardLine(isRunning: false, runningLine: nil, seconds: 3600)
                == .listened(hours: 1))
        #expect(RadioMyStations.cardLine(isRunning: false, runningLine: nil, seconds: 3600 * 3 + 59)
                == .listened(hours: 3))
    }

    /// A station that has started but sent no title yet must NOT fall back to
    /// its listening time. The line would flip to the show a moment later,
    /// and a card that changes its statement twice in two seconds reads as
    /// broken.
    @Test func aRunningStationWithoutATitleStaysEmptyRatherThanShowingHours() {
        #expect(RadioMyStations.cardLine(isRunning: true, runningLine: nil, seconds: 99_999) == .none)
        #expect(RadioMyStations.cardLine(isRunning: true, runningLine: "", seconds: 99_999) == .none)
    }
}

/// The tile ground. Capped hue, brightness counter to the logo.
@Suite struct RadioTileGroundTests {

    /// The two named numbers, pinned so a report can cite them and a reader
    /// can turn them.
    @Test func theNamedConstants() {
        #expect(RadioTileGround.saturationCap == 0)   // Grauskala
        #expect(RadioTileGround.luminanceThreshold == 0.5)
    }

    /// Counter-brightness, few steps, both modes. A dark logo gets a light
    /// ground and vice versa, in EACH mode.
    @Test func brightnessRunsCounterToTheLogo() {
        // Light mode: dark logo → light ground, light logo → dark ground.
        #expect(RadioTileGround.brightness(logoLuminance: 0.1, darkMode: false)
                > RadioTileGround.brightness(logoLuminance: 0.9, darkMode: false))
        // Dark mode: same direction, darker palette.
        #expect(RadioTileGround.brightness(logoLuminance: 0.1, darkMode: true)
                > RadioTileGround.brightness(logoLuminance: 0.9, darkMode: true))
        // Few steps: the same side of the threshold gives the SAME value.
        #expect(RadioTileGround.brightness(logoLuminance: 0.1, darkMode: false)
                == RadioTileGround.brightness(logoLuminance: 0.3, darkMode: false))
    }

    /// Alpha-weighted: transparent pixels do not vote. A dark glyph on a
    /// transparent PNG must read as DARK, not as half-transparent grey.
    @Test func transparencyDoesNotVote() {
        let side = 8
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: CGSize(width: side, height: side),
                                            format: format).image { ctx in
            // Mostly transparent, one dark square.
            UIColor.black.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
        }
        #expect(RadioTileGround.luminance(of: image) < 0.2)

        let light = UIGraphicsImageRenderer(size: CGSize(width: side, height: side),
                                            format: format).image { ctx in
            UIColor.white.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
        }
        #expect(RadioTileGround.luminance(of: light) > 0.8)
    }
}

/// The card ground is the logo's BOTTOM EDGE colour. The gradient
/// attaches there; seamless join has priority over the old counter rule.
@Suite struct RadioCardToneTests {

    private func image(draw: (UIGraphicsImageRendererContext) -> Void) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: 32, height: 32),
                                       format: format).image(actions: draw)
    }

    /// bigFM class: dark logo body ending in a black lower edge. The ground
    /// must BE that edge, not a whole-image mix.
    @Test func groundIsTheBottomEdge() throws {
        let img = image { ctx in
            UIColor.white.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 32, height: 16))
            UIColor.black.setFill()
            ctx.fill(CGRect(x: 0, y: 16, width: 32, height: 16))
        }
        let edge = try #require(RadioTileGround.bottomEdgeColor(of: img))
        #expect(edge.luminance < 0.1)   // the black band, not the 0.5 mean
    }

    /// Transparent strip below the mark: the sampler walks UP to the next
    /// zone that carries ink instead of answering "nothing".
    @Test func transparentStripFallsThrough() throws {
        let img = image { ctx in
            UIColor.white.setFill()
            ctx.fill(CGRect(x: 0, y: 8, width: 32, height: 16))  // ink mid-image
        }
        let edge = try #require(RadioTileGround.bottomEdgeColor(of: img))
        #expect(edge.luminance > 0.8)
    }

    /// A fully transparent image answers nil. The card keeps its fallback.
    @Test func emptyImageAnswersNil() {
        let img = image { _ in }
        #expect(RadioTileGround.bottomEdgeColor(of: img) == nil)
    }

    /// Title ink follows the GROUND: white on dark, dark on light.
    @Test func titleInkFollowsTheGround() {
        #expect(RadioTileGround.titleIsLight(groundLuminance: 0.1))
        #expect(!RadioTileGround.titleIsLight(groundLuminance: 0.9))
    }

    /// Full tone only for a DOMINANT edge. The 1LIVE class (the
    /// mark IS the colour) versus the WDR-2 class (the edge catches an
    /// accent bar of a differently coloured mark).
    @Test func dominanceSeparatesFullToneFromAccent() throws {
        // Mark almost entirely red, red bottom edge → dominant.
        let solid = image { ctx in
            UIColor.red.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 32, height: 32))
        }
        let solidEdge = try #require(RadioTileGround.bottomEdgeColor(of: solid))
        #expect(RadioTileGround.dominance(of: solid, edge: solidEdge)
                >= RadioTileGround.dominanceShare)
        // Mostly blue mark, thin red bottom bar → the edge is an ACCENT.
        let accent = image { ctx in
            UIColor.blue.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 32, height: 28))
            UIColor.red.setFill()
            ctx.fill(CGRect(x: 0, y: 28, width: 32, height: 4))
        }
        let accentEdge = try #require(RadioTileGround.bottomEdgeColor(of: accent))
        #expect(accentEdge.red > 0.8, "die Kante muss den roten Balken erwischen")
        #expect(RadioTileGround.dominance(of: accent, edge: accentEdge)
                < RadioTileGround.dominanceShare)
    }

    /// The calmed variant keeps the HUE. It is the same tone, quieter.
    @Test func dampenedKeepsTheHue() {
        let edge = RadioTileGround.Edge(red: 0.89, green: 0.03, blue: 0.16, luminance: 0.22)
        var hue: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        UIColor(RadioTileGround.dampened(edge)).getHue(&hue, saturation: &s, brightness: &b, alpha: &a)
        var edgeHue: CGFloat = 0
        UIColor(red: 0.89, green: 0.03, blue: 0.16, alpha: 1).getHue(&edgeHue, saturation: &s, brightness: &b, alpha: &a)
        #expect(abs(Double(hue - edgeHue)) < 0.03)
        // Dark edge → the light pastel step; ink accordingly dark.
        #expect(RadioTileGround.dampenedLuminance(edge) > 0.5)
    }
}
