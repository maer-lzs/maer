// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
import SwiftUI
@testable import Maer

/// A detail page in two columns divides at the fold, its cover leaves the
/// main button above the playback bar, and its two buttons stand whole.
struct DetailColumnsTests {
    @Test("die offene Duo teilt am Falz, die Seitenspalte nimmt nur der rechten Spalte Breite")
    func theOpenDuoDividesAtTheFold() {
        // Measured on the open Duo: window 951, fold 455.5 to 495.5, the page
        // ends at the side column (867).
        let columns = FoldSplit.columns(contentMinX: 0, contentWidth: 867, fold: 455.5...495.5, windowWidth: 951)
        #expect(columns == .init(leading: 455.5, gap: 40, trailing: 371.5))
    }

    @Test("ohne Falz teilt die Mitte der Anzeige, nicht die der Seite")
    func withoutAFoldTheDisplayMiddle() {
        // An iPad in landscape: the page spans the window.
        #expect(FoldSplit.columns(contentMinX: 0, contentWidth: 1366, fold: nil, windowWidth: 1366)
                == .init(leading: 683, gap: 0, trailing: 683))
        // A page that leaves a side column free still divides at the display's middle.
        #expect(FoldSplit.columns(contentMinX: 0, contentWidth: 867, fold: nil, windowWidth: 951)
                == .init(leading: 475.5, gap: 0, trailing: 391.5))
    }

    @Test("ein Falz ausserhalb der Seite schiebt keine Spalte unter null")
    func aFoldOutsideThePageStaysInside() {
        let columns = FoldSplit.columns(contentMinX: 100, contentWidth: 300, fold: 20...60, windowWidth: 951)
        #expect(columns.leading == 0 && columns.gap == 0 && columns.trailing == 300)
    }

    @Test("das Cover nimmt seine Groesse einmal aus dem Raum, nie aus dem, was darunter steht")
    func theCoverTakesItsSizeFromTheRoom() {
        // Folded Duo upright: 678 high, 412 for the column; a share of the
        // height below the cover's top.
        #expect(DetailCoverSide.side(columnWidth: 412, height: 678, top: 48) == 346)
        // iPhone 17: the full width fits.
        #expect(DetailCoverSide.side(columnWidth: 370, height: 874, top: 78) == 370)
        // Never under the minimum, never over the column.
        #expect(DetailCoverSide.side(columnWidth: 407, height: 300, top: 60) == DetailCoverSide.minimum)
        #expect(DetailCoverSide.side(columnWidth: 120, height: 400, top: 60) == 120)
        // Whole points: the side lands on the pixel it asks for.
        #expect(DetailCoverSide.side(columnWidth: 500, height: 701, top: 0).truncatingRemainder(dividingBy: 1) == 0)
    }

    /// The pages that go two-column in a wide window, and the one way each
    /// takes there.
    nonisolated static let framedPages: [(file: String, frame: String)] = [
        ("Sources/Views/BookDetailScreen.swift", "FoldColumns { column in"),
        ("Sources/Views/Podcasts/PodcastShowView.swift", "DetailListColumns {"),
        ("Sources/Views/Music/MusicAlbumView.swift", "DetailListColumns {"),
        ("Sources/Views/Music/MusicBrowseViews.swift", "DetailScrollColumns(spacing:"),
        ("Sources/Views/Music/MusicLibraryPages.swift", "DetailListColumns {"),
        ("Sources/Views/Radio/RadioStationDetailView.swift", "DetailScrollColumns(spacing:"),
        ("Sources/Views/Podcasts/PodcastEpisodeDetailView.swift", "DetailScrollColumns(spacing:"),
        ("Sources/Views/CatalogSourcePage.swift", "DetailScrollColumns(spacing:"),
        // The full player, side by side on a display with a fold.
        ("Sources/Views/PlayerView.swift", "FoldColumns { column in"),
    ]

    @Test("das erste Zeichen jeder Liste steht gleich weit vom Rand und vom Falz", .needsTheSources)
    func everyListsFirstMarkStandsAtTheGutter() throws {
        // The album's track number leads its column; the episode row keeps
        // the page's standard margin, not a smaller one of its own.
        let bars = SyncContractFenceTests.stripped(try String(
            contentsOf: SourceTree.root.appendingPathComponent("Sources/Views/Music/PopularityBars.swift"), encoding: .utf8))
        #expect(bars.contains(".frame(width: numberWidth, alignment: .leading)"))
        let rows = SyncContractFenceTests.stripped(try String(
            contentsOf: SourceTree.root.appendingPathComponent("Sources/Views/Podcasts/PodcastComponents.swift"), encoding: .utf8))
        #expect(rows.contains(".padding(.horizontal, FoldSplit.pageGutter)\n        .padding(.vertical, 10)"))
        #expect(!rows.contains(".padding(.horizontal, 12)\n        .padding(.vertical, 10)"), "the episode row keeps a margin of its own")
    }

    @Test("jede Seite mit Kopf und Inhalt nimmt den einen Rahmen", .needsTheSources)
    func everyHeadedPageTakesTheFrame() throws {
        // Every page with the head (`DetailHeaderTests.headedPages`) stands in
        // one of the frames; pure lists without a head stay in one column.
        let framed = Set(Self.framedPages.map(\.file))
        for page in DetailHeaderTests.headedPages {
            #expect(framed.contains(page.file), "\(page.file) has a head but no frame at the fold")
        }
    }

    @Test("Buchseite, Sendung, Album und Playlist, Kuenstler nehmen den einen Rahmen", .needsTheSources)
    func everyDetailPageTakesTheFrame() throws {
        for page in Self.framedPages {
            let text = SyncContractFenceTests.stripped(
                try String(contentsOf: SourceTree.root.appendingPathComponent(page.file), encoding: .utf8))
            #expect(text.components(separatedBy: page.frame).count - 1 == 1, "\(page.file) builds its own columns")
        }
        // The frames divide only through `FoldColumns`, and that only through the rule.
        let frame = try String(contentsOf: SourceTree.root.appendingPathComponent("Sources/Views/FoldColumns.swift"),
                               encoding: .utf8)
        #expect(frame.components(separatedBy: "FoldSplit.columns(").count - 1 == 1)
        #expect(frame.components(separatedBy: "FoldColumns {").count - 1 == 2)
    }

    @Test("beide Spalten stehen gleich weit vom Falz, die Strecke liegt im Rahmen", .needsTheSources)
    @MainActor
    func bothColumnsStandEquallyFarFromTheFold() throws {
        #expect(FoldColumns<EmptyView, EmptyView>.foldMargin + FoldSplit.pageGutter == FoldSplit.foldDistance)
        let frame = SyncContractFenceTests.stripped(
            try String(contentsOf: SourceTree.root.appendingPathComponent("Sources/Views/FoldColumns.swift"), encoding: .utf8))
        // The leading column's trailing edge and the trailing column's leading edge, once each.
        #expect(frame.components(separatedBy: ".padding(.trailing, margin)").count - 1 == 1)
        #expect(frame.components(separatedBy: ".padding(.leading, margin)").count - 1 == 1)
        #expect(frame.contains("List { rows().rowsTakeTheFoldGutter() }"))
        // Every division writes its numbers, so the distances can be read off the device.
        #expect(frame.contains("Logger.library.notice(\"FOLD split band="))
        // The book page keeps the gutter at the fold: its left column, the chapter heading and rows.
        let page = SyncContractFenceTests.stripped(
            try String(contentsOf: SourceTree.root.appendingPathComponent("Sources/Views/BookDetailScreen.swift"), encoding: .utf8))
        #expect(page.contains(".padding(.leading, 24)\n                .padding(.trailing, FoldSplit.pageGutter)"))
        #expect(page.contains(".padding(.leading, FoldSplit.pageGutter)\n                    .padding(.trailing, 20)"))
        #expect(page.contains("EdgeInsets(top: 8, leading: FoldSplit.pageGutter, bottom: 8, trailing: 20)"))
    }

    /// A layout pass in the model of the measured loop: the cover lands on a
    /// third of a point, and the measured height below it moves by the
    /// part of its side that the pixel grid swallows.
    private static func measuredBelow(side: CGFloat) -> CGFloat {
        let landed = (side * 3).rounded() / 3
        return 305 + (side - landed) * 3
    }

    /// The full player's measured layout in the model: the cover takes the
    /// height the controls leave, in whole points.
    private static func sideLeft(by kept: CGFloat) -> CGFloat {
        min(412, 678 - kept - 126.5).rounded(.down)
    }

    @Test("ein gemessenes Mass kommt nach endlich vielen Durchlaeufen zur Ruhe")
    func aMeasuredHeightSettlesAfterFinitelyManyPasses() {
        // Unsettled, the model swings without end: the loop a measuring
        // page showed (100 % CPU, the setters on the main thread).
        var raw: CGFloat = 0
        var rawSides: Set<CGFloat> = []
        for _ in 0..<20 {
            let side = min(412, 678 - raw - 126.5)
            rawSides.insert(side)
            raw = Self.measuredBelow(side: side)
        }
        #expect(rawSides.count > 1, "the model does not show the swing it stands for")
        // Settled: whole-point sides and a change under a point kept out.
        var kept: CGFloat = 0
        var passes = 0
        var lastSide: CGFloat = -1
        while passes < 20 {
            let side = Self.sideLeft(by: kept)
            let next = DetailCoverSide.settled(kept, measured: Self.measuredBelow(side: side))
            passes += 1
            if side == lastSide && next == kept { break }
            lastSide = side
            kept = next
        }
        #expect(passes < 5, "the layout did not come to rest: \(passes) passes")
    }

    @Test("auch eine Schwingung ab einem Punkt endet: die gehaltene Hoehe kehrt zu keinem verlassenen Wert zurueck")
    func aSwingOfWholePointsEndsToo() {
        // A layout that answers a large cover with a tall height and a small
        // cover with a short one, 4 pt apart: the height shrinks the cover,
        // the cover shrinks the height, and back; unsettled it flips for ever.
        func measured(side: CGFloat) -> CGFloat { side >= 249 ? 305 : 301 }
        var kept: CGFloat = 0
        var seen: [CGFloat] = []
        for _ in 0..<20 {
            let side = min(412, 678 - kept - 126).rounded(.down)
            kept = DetailCoverSide.settled(kept, measured: measured(side: side))
            seen.append(kept)
        }
        #expect(Set(seen.suffix(10)).count == 1, "the kept height still moves: \(seen)")
        #expect(seen == seen.sorted(), "the kept height went back: \(seen)")
        // Shorter measurements under the kept height never lower it.
        #expect(DetailCoverSide.settled(305, measured: 301) == 305)
        #expect(DetailCoverSide.settled(305, measured: 305.4) == 305)
        #expect(DetailCoverSide.settled(305, measured: 306.2) == 307)
        // A first pass that measured the block taller than it settles is let
        // go once the drop is clear: the player's controls, 330 then 301.
        #expect(DetailCoverSide.settled(330, measured: 301.4) == 302)
        #expect(DetailCoverSide.settled(305, measured: 305 - DetailCoverSide.shrinkStep + 0.5) == 305)
    }

    @Test("keine Detailseite misst, was unter dem Cover steht; der Player haelt sein Mass ueber den Stillstand", .needsTheSources)
    func noDetailPageMeasuresBelowTheCover() throws {
        // The cover's size comes from the room alone, so it does not change
        // between the first frame and rest.
        for file in ["Sources/Views/BookDetailScreen.swift", "Sources/Views/DetailHeader.swift"] {
            let text = SyncContractFenceTests.stripped(
                try String(contentsOf: SourceTree.root.appendingPathComponent(file), encoding: .utf8))
            #expect(!text.contains("DetailCoverSide.settled("), "\(file) settles a measured height")
            #expect(!text.contains("bottomBarInset"), "\(file) sizes the cover to the playback bar")
            #expect(!text.contains("belowCover") && !text.contains("noteBelow"), "\(file) measures below the cover")
        }
        let player = SyncContractFenceTests.stripped(
            try String(contentsOf: SourceTree.root.appendingPathComponent("Sources/Views/PlayerView.swift"), encoding: .utf8))
        #expect(player.contains("controlsHeight = DetailCoverSide.settled(controlsHeight, measured: $0)"))
    }

    @Test("zwei Knoepfe nebeneinander nur, wo beide ganz Platz haben")
    func twoButtonsSideBySideOnlyWhereTheyFit() {
        let standard = DetailButtonRow.sideBySideMinWidth
        #expect(DetailButtonRow.stacked(width: 342, needs: standard))
        #expect(!DetailButtonRow.stacked(width: 407, needs: standard))
        #expect(!DetailButtonRow.stacked(width: standard, needs: standard))
        // Large type: the same column stacks them.
        #expect(DetailButtonRow.stacked(width: 407, needs: standard * 1.35))
    }

    @Test("die Buchseite skaliert den Bedarf der Knopfreihe mit der Schrift", .needsTheSources)
    func theNeedScalesWithTheType() throws {
        let page = SyncContractFenceTests.stripped(
            try String(contentsOf: SourceTree.root.appendingPathComponent("Sources/Views/BookDetailScreen.swift"), encoding: .utf8))
        #expect(page.contains("@ScaledMetric(relativeTo: .body) private var buttonPairWidth: CGFloat = DetailButtonRow.sideBySideMinWidth"))
        #expect(page.contains("@ScaledMetric(relativeTo: .body) private var compactPairWidth: CGFloat = DetailButtonRow.compactMinWidth"))
        #expect(page.contains("DetailButtonRow.form(width: width, needs: buttonPairWidth, compactNeeds: compactPairWidth)"))
    }

    @Test("zwischen voller Zeile und untereinander stehen die zwei Knoepfe knapp in einer Zeile")
    func theCompactRowStandsBetween() {
        let full = DetailButtonRow.sideBySideMinWidth, compact = DetailButtonRow.compactMinWidth
        #expect(DetailButtonRow.form(width: 380, needs: full, compactNeeds: compact) == .sideBySide)
        #expect(DetailButtonRow.form(width: 342, needs: full, compactNeeds: compact) == .compact)
        #expect(DetailButtonRow.form(width: 240, needs: full, compactNeeds: compact) == .stacked)
        // Large type scales both needs: the same width stacks.
        #expect(DetailButtonRow.form(width: 342, needs: full * 1.35, compactNeeds: compact * 1.35) == .stacked)
    }

    @Test("das Cover steht immer als Karte, auch wo die volle Breite passt")
    func theCoverIsACard() {
        // iPhone 17: the full width would fit; a card with the gap at its sides.
        #expect(DetailCoverCard.form(width: 402, height: 874, safeTop: 62)
                == .init(side: 402 - 2 * DetailCoverCard.gap, top: 62 + DetailCoverCard.gap))
        // Folded Duo upright: smaller than the page, a card under the status bar.
        let card = DetailCoverCard.form(width: 412, height: 678, safeTop: 32)
        #expect(card.top == 32 + DetailCoverCard.gap)
        #expect(card.side == DetailCoverSide.side(columnWidth: 412 - 2 * DetailCoverCard.gap, height: 678,
                                                  top: card.top))
        #expect(card.side < 412 - 2 * DetailCoverCard.gap + 1)
    }

    @Test("der grosse Player passt auf eine Ansicht: das Cover gibt nach bis auf null, die Bedienung nie")
    func thePlayerFitsOneView() {
        // Upright: as wide as the bar, never taller than the area the
        // controls leave, down to nothing; the book page keeps its minimum.
        #expect(PlayerFit.uprightCover(barWidth: 302, areaHeight: 400) == 302)
        #expect(PlayerFit.uprightCover(barWidth: 302, areaHeight: 266.6) == 266)
        #expect(PlayerFit.uprightCover(barWidth: 302, areaHeight: -12) == 0)
        // The bar takes the cover's width, one width for both; a cover that
        // gave way below the minimum leaves the bar its own room.
        #expect(PlayerFit.uprightBar(coverSide: 266) == 266)
        #expect(PlayerFit.uprightBar(coverSide: PlayerFit.barMinimum) == PlayerFit.barMinimum)
        #expect(PlayerFit.uprightBar(coverSide: 120) == nil)
        #expect(DetailCoverSide.side(columnWidth: 402, height: 340, top: 80) == 160)
        // Across without a fold: the fixed side, smaller where the height is.
        #expect(PlayerFit.sideBySideCover(fixed: 300, viewportHeight: 360, margin: 16) == 300)
        #expect(PlayerFit.sideBySideCover(fixed: 300, viewportHeight: 250, margin: 16) == 218)
        // Controls that alone exceed the view are reported.
        #expect(PlayerFit.controlsOverflow(controls: 700, viewportHeight: 700, margin: 16))
        #expect(!PlayerFit.controlsOverflow(controls: 400, viewportHeight: 700, margin: 16))
    }

    @Test("der Zieh-Strich steht knapp unter der Statuszeile, das Cover seinen Abstand darunter", .needsTheSources)
    func theHandleStandsUnderTheStatusBar() throws {
        // iPhone 17: reserved top edge 62 pt.
        #expect(PlayerGrabHandle.top(topInset: 62) == 56)
        #expect(PlayerGrabHandle.coverTop(topInset: 62) == 73)
        // No reserved edge: never closer to the display's edge than 6 pt.
        #expect(PlayerGrabHandle.top(topInset: 0) == 6)
        #expect(PlayerGrabHandle.coverTop(topInset: 0) == 23)
        let read = { (path: String) in
            SyncContractFenceTests.stripped(
                try String(contentsOf: SourceTree.root.appendingPathComponent(path), encoding: .utf8))
        }
        #expect(try read("Sources/Views/FullPlayerOverlay.swift")
            .contains(".padding(.top, PlayerGrabHandle.top(topInset: topInset))"))
        #expect(try read("Sources/Views/PlayerView.swift")
            .contains("? 16 : PlayerGrabHandle.coverTop(topInset: topInset) - topInset)"))
    }

    @Test("das Cover des Players steht aufgeklappt gleich weit von Aussenrand und sichtbarem Falz")
    func theCoverStandsMidwayToTheVisibleFold() {
        // The open Duo: band 455.5 to 495.5, the visible fold in its middle.
        let fold: ClosedRange<CGFloat> = 455.5...495.5
        let margin = FoldSplit.foldDistance - FoldSplit.pageGutter
        let column = fold.lowerBound - margin
        let side = column - 32
        let left = column / 2 + FoldSplit.shiftToFoldMiddle(fold: fold) - side / 2
        let right = left + side
        let visibleFold = (fold.lowerBound + fold.upperBound) / 2
        #expect(left == visibleFold - right, "edge \(left), fold \(visibleFold - right)")
        // The cover stays clear of the band.
        #expect(right < fold.lowerBound)
    }

    @Test("Buchseite und Player tragen die eine Form der Karte", .needsTheSources)
    func bookPageAndPlayerShareTheCard() throws {
        let page = SyncContractFenceTests.stripped(
            try String(contentsOf: SourceTree.root.appendingPathComponent("Sources/Views/BookDetailScreen.swift"), encoding: .utf8))
        #expect(page.contains("let coverForm = DetailCoverCard.form("))
        #expect(page.contains("heroCover(side: coverForm.side)"))
        let player = SyncContractFenceTests.stripped(
            try String(contentsOf: SourceTree.root.appendingPathComponent("Sources/Views/PlayerView.swift"), encoding: .utf8))
        #expect(player.contains(".frame(width: maxSide, height: maxSide)\n        .clipped()\n        .coverCard()"))
        // A picture of any aspect ratio fits inside the square, as on the book page.
        #expect(player.contains("CoverFitting(image: image, pixelSize: pixels, backdrop: .blurredSelf)"))
        #expect(!player.contains("ScrollView"), "the full player scrolls again")
        // Upright the cover is as wide as the progress bar under it and takes
        // the area the controls leave, laid out, not measured.
        #expect(player.contains("GeometryReader { area in\n                                let side = PlayerFit.uprightCover(\n                                    barWidth: area.size.width - 2 * PlayerDismissZones.scrubberInset,"))
        // The bar under it takes the same width (`PlayerFit.uprightBar`).
        #expect(player.contains(".onChange(of: side, initial: true) { _, side in uprightCoverSide = side }"))
        #expect(player.contains(".frame(maxWidth: uprightCoverSide.flatMap(PlayerFit.uprightBar) ?? .infinity)"))
        // The content never grows past the window and moves the side column.
        #expect(player.contains(".padding(columnPlacement?.edge ?? [], columnPlacement?.strip ?? 0)\n            .frame(width: geo.size.width, height: geo.size.height)"))
        // Beside the side column and at the fold the cover takes the room it has, not the fixed side.
        // At the fold, side by side, upright, and the definition.
        #expect(player.components(separatedBy: "cover(maxSide:").count - 1 == 4)
        #expect(player.contains("private static let coverSide: CGFloat = 300"))
        #expect(!player.contains("RoundedRectangle(cornerRadius: 12))\n        .shadow("), "the player keeps a card of its own")
    }
}
#endif
