// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// The marks on a cover stand at the top right in one order, as many as
/// fit above the corner control, and one tone draws every mark and pill.
struct CoverGlyphsTests {

    @Test("die Zeichen stehen in der einen Reihenfolge, jedes einmal, gleich in welcher Folge sie kommen")
    func theStackKeepsTheOrder() {
        let all = CoverGlyphs.stack([.count, .favourite, .finished, .availability, .lock, .kind], room: .max)
        #expect(all.shown == [.kind, .lock, .availability, .finished, .favourite, .count], "\(all.shown)")
        #expect(all.hidden.isEmpty)
        let twice = CoverGlyphs.stack([.availability, .lock, .availability], room: .max)
        #expect(twice.shown == [.lock, .availability], "a mark given twice stands twice: \(twice.shown)")
    }

    @Test("Schloss und Offline stehen untereinander, das Schloss oben")
    func lockAndOfflineStandOneUnderTheOther() {
        let tile = CoverGlyphs.stack([.availability, .lock], room: 3)
        #expect(tile.shown == [.lock, .availability] && tile.hidden.isEmpty, "\(tile)")
    }

    @Test("was ueber dem Play nicht Platz hat, faellt von unten weg und bleibt gesagt")
    func whatDoesNotFitIsHiddenFromTheBottom() {
        let split = CoverGlyphs.stack([.kind, .lock, .availability, .finished], room: 2)
        #expect(split.shown == [.kind, .lock] && split.hidden == [.availability, .finished], "\(split)")
        #expect(CoverGlyphs.stack([.lock], room: 0) == ([], [.lock]))
        #expect(CoverGlyphs.stack([.lock], room: -3) == ([], [.lock]), "a negative room shows a mark")
    }

    @Test("der Platz: Kachel weniger Ecke, durch die Hoehe eines Zeichens; ungemessen verbirgt nichts")
    func theRoomAboveTheCorner() {
        #expect(CoverGlyphs.room(coverSide: 150, glyphSide: 32, cornerSide: 32) == 3)
        #expect(CoverGlyphs.room(coverSide: 150, glyphSide: 50, cornerSide: 50) == 2, "a larger text size keeps the room")
        #expect(CoverGlyphs.room(coverSide: 40, glyphSide: 32, cornerSide: 32) == 0)
        #expect(CoverGlyphs.room(coverSide: 20, glyphSide: 32, cornerSide: 32) == 0, "a cover smaller than its corner fits a mark")
        #expect(CoverGlyphs.room(coverSide: nil, glyphSide: 32, cornerSide: 32) == .max, "an unmeasured cover hides a mark")
        #expect(CoverGlyphs.room(coverSide: .nan, glyphSide: 32, cornerSide: 32) == 0)
        #expect(CoverGlyphs.room(coverSide: 150, glyphSide: 0, cornerSide: 32) == 0, "a mark without height fits endlessly")
    }

    @Test("die Kachel stapelt Schloss und Offline in der einen Komponente, ein Ton fuer Zeichen und Pillen", .needsTheSources)
    func theTileStacksAndOneToneDraws() throws {
        let tile = try FetchAnswerTests.squeezedSource("Sources/Views/MediaTile.swift")
        #expect(tile.contains(".overlay(alignment: .topTrailing) { CoverGlyphStack(present: marks,"),
                "the tile's marks stand outside the stack")
        #expect(!tile.contains(".offlineUnavailableBadge(") && !tile.contains(".overlay(alignment: .topTrailing) { PremiumLockBadge("),
                "the lock and the offline disc take the same corner again")
        var literal: [String] = []
        for (name, text) in ProjectFileIntegrityTests.sourceTexts(in: ["Sources/Views"])
        where SyncContractFenceTests.stripped(text).contains(".white.opacity(0.22)") {
            literal.append(name)
        }
        #expect(literal == ["CoverGlyphStack.swift"], "a pill or mark writes the tone by hand: \(literal.sorted())")
    }
}
#endif
