// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
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

    @Test("das Cover wird so klein, dass der Hauptknopf in Ruhe ueber der Leiste steht")
    func theCoverLeavesTheMainButtonFree() {
        // Folded Duo upright: 678 high, 466 wide; the block down to the main
        // button 305, the bar's reserve 126.
        let side = DetailCoverSide.side(columnWidth: 412, height: 678, top: 0, below: 305, bottomReserve: 126)
        #expect(side == 247)
        // iPhone 17: the full width fits, nothing shrinks.
        #expect(DetailCoverSide.side(columnWidth: 402, height: 874, top: 0, below: 305, bottomReserve: 126) == 402)
        // Never under the minimum, never over the column.
        #expect(DetailCoverSide.side(columnWidth: 407, height: 400, top: 60, below: 305, bottomReserve: 126)
                == DetailCoverSide.minimum)
        #expect(DetailCoverSide.side(columnWidth: 120, height: 400, top: 60, below: 305, bottomReserve: 126) == 120)
    }

    /// The pages that go two-column in a wide window, and the one way each
    /// takes there.
    nonisolated static let framedPages: [(file: String, frame: String)] = [
        ("Sources/Views/BookDetailScreen.swift", "FoldColumns { column in"),
        ("Sources/Views/Podcasts/PodcastShowView.swift", "DetailListColumns {"),
        ("Sources/Views/Music/MusicAlbumView.swift", "DetailListColumns {"),
        ("Sources/Views/Music/MusicBrowseViews.swift", "DetailScrollColumns(spacing:"),
    ]

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

    /// A layout pass in the model of the measured loop: the cover lands on a
    /// third of a point, and the measured height below it moves by the
    /// part of its side that the pixel grid swallows.
    private static func measuredBelow(side: CGFloat) -> CGFloat {
        let landed = (side * 3).rounded() / 3
        return 305 + (side - landed) * 3
    }

    @Test("Cover und gemessene Hoehe darunter kommen nach endlich vielen Durchlaeufen zur Ruhe")
    func theCoverSettlesAfterFinitelyManyPasses() {
        // Unsettled, the model swings without end: the loop the page showed
        // (100 % CPU, the setters of both measurements on the main thread).
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
            let side = DetailCoverSide.side(columnWidth: 412, height: 678, top: 0, below: kept, bottomReserve: 126.5)
            let next = DetailCoverSide.settled(kept, measured: Self.measuredBelow(side: side))
            passes += 1
            if side == lastSide && next == kept { break }
            lastSide = side
            kept = next
        }
        #expect(passes < 5, "the cover did not come to rest: \(passes) passes")
        #expect(DetailCoverSide.side(columnWidth: 412, height: 678, top: 0, below: kept, bottomReserve: 126.5)
                    .truncatingRemainder(dividingBy: 1) == 0)
    }

    @Test("Buchseite und Player halten die gemessene Hoehe nur ueber die Regel des Stillstands", .needsTheSources)
    func theMeasurementsGoThroughTheSettle() throws {
        let page = SyncContractFenceTests.stripped(
            try String(contentsOf: SourceTree.root.appendingPathComponent("Sources/Views/BookDetailScreen.swift"), encoding: .utf8))
        #expect(page.contains("belowCover = DetailCoverSide.settled(belowCover, measured:"))
        // Four measurements (cover and play button in both forms) and the definition.
        #expect(page.components(separatedBy: "noteBelowCover()").count - 1 == 5, "a measurement sets the height by itself")
        #expect(!page.contains("private var belowCover: CGFloat {"), "the height is read raw from the two measurements")
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
        #expect(page.contains("DetailButtonRow.stacked(width: width, needs: buttonPairWidth)"))
    }
}
#endif
