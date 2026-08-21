// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Testing
import Foundation
import UIKit
import SwiftUI
@testable import ABSPlayer

/// cb2d1ed: the "My Stations" row — composition, the exclusion fence, and the
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
    /// It is not gone — it stands one row lower.
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

    /// 776d548 (the owner, hart): KEIN Favorit verschwindet — die Vollseite
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
    /// its listening time — the line would flip to the show a moment later,
    /// and a card that changes its statement twice in two seconds reads as
    /// broken.
    @Test func aRunningStationWithoutATitleStaysEmptyRatherThanShowingHours() {
        #expect(RadioMyStations.cardLine(isRunning: true, runningLine: nil, seconds: 99_999) == .none)
        #expect(RadioMyStations.cardLine(isRunning: true, runningLine: "", seconds: 99_999) == .none)
    }
}

/// 773d87b: the tile ground — capped hue, brightness counter to the logo.
@Suite struct RadioTileGroundTests {

    /// The two named numbers, pinned so the report can cite them and the owner
    /// can turn them.
    @Test func theNamedConstants() {
        #expect(RadioTileGround.saturationCap == 0)   // 97e3a5a: Grauskala, FINAL
        #expect(RadioTileGround.luminanceThreshold == 0.5)
    }

    /// Counter-brightness, few steps, both modes — a dark logo gets a light
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

/// 804fe18: the card ground keeps the HUE, the brightness runs counter.
@Suite struct RadioCardToneTests {

    @Test func darkLogoGetsTheLightVariant() {
        let dark = RadioTileGround.cardBrightness(logoLuminance: 0.1)
        let light = RadioTileGround.cardBrightness(logoLuminance: 0.9)
        #expect(dark.brightness > light.brightness)
        // Few steps: same side of the threshold, same values.
        #expect(RadioTileGround.cardBrightness(logoLuminance: 0.2).brightness == dark.brightness)
    }

    /// The HUE survives the re-tone — the counter rule moves brightness and
    /// saturation only. (WDR 5 stays WDR-blue, just light enough to carry a
    /// dark logo.)
    @Test func theHueSurvives() {
        let base = Color(hue: 0.6, saturation: 0.8, brightness: 0.2)
        let toned = RadioTileGround.cardTone(of: base, logoLuminance: 0.1)
        var hue: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        UIColor(toned).getHue(&hue, saturation: &s, brightness: &b, alpha: &a)
        #expect(abs(Double(hue) - 0.6) < 0.02)
        #expect(Double(b) > 0.8)   // light variant for the dark logo
    }
}
