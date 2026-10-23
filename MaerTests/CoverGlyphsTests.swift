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
        let split = CoverGlyphs.stack([.kind, .lock, .finished, .favourite], room: 2)
        #expect(split.shown == [.kind, .lock] && split.hidden == [.finished, .favourite], "\(split)")
        #expect(CoverGlyphs.stack([.lock], room: 0) == ([], [.lock]))
        #expect(CoverGlyphs.stack([.lock], room: -3) == ([], [.lock]), "a negative room shows a mark")
    }

    @Test("die Verfuegbarkeit bleibt sichtbar, solange ein Zeichen Platz hat; die Zeichen darueber weichen")
    func availabilityIsNeverTheOneHidden() {
        let one = CoverGlyphs.stack([.lock, .availability], room: 1)
        #expect(one.shown == [.availability] && one.hidden == [.lock], "a dimmed cover carries offline alone: \(one)")
        let two = CoverGlyphs.stack([.kind, .lock, .availability, .finished], room: 2)
        #expect(two.shown == [.kind, .availability] && two.hidden == [.lock, .finished], "\(two)")
        let fits = CoverGlyphs.stack([.kind, .availability, .count], room: 2)
        #expect(fits.shown == [.kind, .availability], "availability is moved although it fits: \(fits)")
        #expect(CoverGlyphs.stack([.availability], room: 0) == ([], [.availability]), "no room still shows a mark")
    }

    @Test("ein Cover ohne Aussage zur Verfuegbarkeit belegt keinen Platz, der Haken abgeschlossen bleibt")
    func anEmptyAvailabilityTakesNoPlace() {
        #expect(CoverAvailability.of(failed: false, downloaded: false, unavailable: false) == nil)
        #expect(CoverAvailability.of(failed: true, downloaded: true, unavailable: true) == .failed)
        #expect(CoverAvailability.of(failed: false, downloaded: true, unavailable: true) == .downloaded)
        #expect(CoverAvailability.of(failed: false, downloaded: false, unavailable: true) == .offline)
        // A finished book in a mixed row, nothing to say about availability,
        // room for two: kind and check, no empty place between them.
        let marks = CoverGlyphs.book(hasKind: true, availability: nil, finished: true)
        #expect(marks == [.kind, .finished], "an empty availability takes a place: \(marks)")
        #expect(CoverGlyphs.stack(marks, room: 2).shown == [.kind, .finished], "the check is pushed out")
        #expect(CoverGlyphs.book(hasKind: false, availability: .offline, finished: true) == [.availability, .finished])
        #expect(CoverGlyphs.book(hasKind: false, availability: nil, finished: false).isEmpty)
    }

    @Test("die Zeichen wachsen bis zur ersten Bedienhilfen-Groesse, der Platz wird in dieser Groesse gemessen", .needsTheSources)
    func theMarksStopGrowing() throws {
        let stack = try FetchAnswerTests.squeezedSource("Sources/Views/CoverGlyphStack.swift")
        #expect(stack.contains("static var largestSize: DynamicTypeSize { .accessibility1 }"))
        #expect(stack.contains(".dynamicTypeSize(...Self.largestSize)"), "the marks grow with every text size again")
        #expect(stack.contains("@ScaledMetric(relativeTo: .title3) private var glyphSide")
                    && stack.contains("CoverGlyphs.room(coverSide: coverSide.map(Double.init), glyphSide: glyphSide,"),
                "the room is not measured inside the capped size")
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

    /// The marks and corner controls that carry the tone: a dark fill of
    /// their own is a mark outside the tone. What still has one stands
    /// here with its reason, counted.
    static let darkFills: [String: (count: Int, reason: String)] = [
        "Sources/Views/KindGlyph.swift": (0, "the kind mark"),
        "Sources/Views/Podcasts/PremiumBadge.swift": (0, "the lock; refused keeps its orange"),
        "Sources/Views/MediaTile.swift": (0, "the play badge"),
        "Sources/Views/FreeCatalogRows.swift": (0, "the import ring"),
        "Sources/Views/CoverBadge.swift": (0, "the offline disc and the downloaded mark"),
        "Sources/Views/BookCoverView.swift": (0, "the book cover's marks; a failed download keeps its accent"),
    ]

    /// The tiles that still mark their kind at the top left, outside the
    /// stack; they take the stack in their own steps.
    static let topLeftKinds: [String: (count: Int, reason: String)] = [
        "Sources/Views/HomeView.swift": (3, "album, catalog track and station tile of Listen Again"),
        "Sources/Views/MixedMediaPage.swift": (6, "book and episode card, album cell, album, track and station tile"),
    ]

    @Test("Zeichen und Ecken tragen den Ton ueber der dunklen Scheibe, die MediaTile stapelt ihre Art", .needsTheSources)
    func theMarksWearTheToneAndTheKindStacks() throws {
        var fills: [String: Int] = [:]
        for path in Self.darkFills.keys {
            let code = SyncContractFenceTests.stripped(try String(contentsOf: SourceTree.root.appendingPathComponent(path), encoding: .utf8))
            fills[path] = code.components(separatedBy: ".black.opacity(").count - 1
        }
        #expect(fills == Self.darkFills.mapValues(\.count), "dark fills of their own per mark file: \(fills)")
        let components = try FetchAnswerTests.squeezedSource("Sources/Views/Podcasts/PodcastComponents.swift")
        let badge = try #require(components.range(of: "struct PodcastSubscribeBadge: View {"))
        let body = components[badge.upperBound...].prefix(1600)
        #expect(!body.contains(".black.opacity(") && !body.contains(".green") && body.components(separatedBy: ".glyphDisc()").count == 4,
                "the subscribe control has a colour of its own again")
        let stack = try FetchAnswerTests.squeezedSource("Sources/Views/CoverGlyphStack.swift")
        #expect(stack.contains("static let shade = Color.black.opacity(0.35)")
                    && stack.contains("Circle().fill(GlyphTone.shade) Circle().fill(GlyphTone.fill)"),
                "the disc is not the tone over the dark shade")
        let tile = try FetchAnswerTests.squeezedSource("Sources/Views/MediaTile.swift")
        #expect(tile.contains("@Environment(\\.coverGlyphKind) private var kind")
                    && tile.contains("(kind == nil ? [] : [.kind])"), "the tile leaves its kind outside the stack")
        let book = try FetchAnswerTests.squeezedSource("Sources/Views/BookCoverView.swift")
        #expect(book.contains("CoverGlyphStack(present: marks, coverSide: size,")
                    && !book.contains(".overlay(alignment: .bottomLeading)"),
                "the book cover's marks stand outside the stack again")
        #expect(book.contains("CoverGlyphs.book(hasKind: kind != nil, availability: availability, finished: finished)"),
                "the book cover builds its marks outside the rule")
        #expect(book.contains("BookCoverStack(availability: CoverAvailability.of(failed: failed,"),
                "the book cover asks no rule what its availability says")
        var left: [String: Int] = [:]
        for (path, text) in try MixedRowGlyphTests.sources() {
            let n = text.components(separatedBy: ".kindGlyph(").count - 1
            if n > 0 { left[path] = n }
        }
        #expect(left == Self.topLeftKinds.mapValues(\.count), "kind marks at the top left: \(left)")
    }
}
#endif
