// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Foundation
import Testing
import UIKit
@testable import Maer

/// The widget's gradient under the text ends in the colour of the cover's
/// bottom edge, which the app computes with the cards' rule and writes into
/// the snapshot (`WidgetSnapshot.coverTint`).
struct WidgetCoverTintTests {
    /// A cover in two bands: `top` over the upper half, `bottom` under it.
    private static func cover(top: UIColor, bottom: UIColor) -> UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: 100, height: 100)).image { context in
            top.setFill(); context.fill(CGRect(x: 0, y: 0, width: 100, height: 50))
            bottom.setFill(); context.fill(CGRect(x: 0, y: 50, width: 100, height: 50))
        }
    }

    @Test("the colour comes from the bottom edge of the cover, darkened as on the cards")
    func theColourIsTheBottomEdge() throws {
        let tint = try #require(CoverColorLoader.bottomComponents(of: Self.cover(top: .white, bottom: .red)))
        #expect(tint.count == 4)
        #expect(abs(tint[0] - 0.7) < 0.03 && tint[1] < 0.03 && tint[2] < 0.03, "not the darkened bottom red: \(tint)")
        let light = try #require(CoverColorLoader.bottomComponents(of: Self.cover(top: .black, bottom: .white)))
        #expect(TextContrast.againstWhite(red: light[0], green: light[1], blue: light[2]) >= TextContrast.readable,
                "white text does not read on a light bottom: \(light)")
        #expect(abs(light[0] - light[1]) < 0.01 && abs(light[1] - light[2]) < 0.01, "a grey bottom left its tone: \(light)")
    }

    @Test("a light cover is darkened in its own tone until white text reaches 4.5:1; a dark one stays")
    func aLightTintDarkensInItsTone() {
        let cream = TextContrast.darkenedForWhite([0.98, 0.95, 0.85, 1])
        #expect(TextContrast.againstWhite(red: cream[0], green: cream[1], blue: cream[2]) >= 4.5)
        #expect(TextContrast.againstWhite(red: cream[0], green: cream[1], blue: cream[2]) < 4.6, "darker than it needs: \(cream)")
        #expect(abs(cream[0] / cream[2] - 0.98 / 0.85) < 0.01 && abs(cream[1] / cream[2] - 0.95 / 0.85) < 0.01,
                "the tone changed: \(cream)")
        #expect(cream[3] == 1)
        let navy = [0.05, 0.08, 0.2, 1.0]
        #expect(TextContrast.darkenedForWhite(navy) == navy, "a dark tint was changed")
        #expect(abs(TextContrast.againstWhite(red: 1, green: 1, blue: 1) - 1) < 0.001)
        #expect(abs(TextContrast.againstWhite(red: 0, green: 0, blue: 0) - 21) < 0.001)
    }

    @Test("a snapshot without a colour reads, one with a colour carries it")
    func aSnapshotWithoutTheColourReads() throws {
        let old = #"{"itemId":"a","title":"T","fraction":0.5,"isPlaying":false}"#
        let read = try JSONDecoder().decode(WidgetSnapshot.self, from: Data(old.utf8))
        #expect(read.coverTint == nil && read.title == "T")
        var written = read
        written.coverTint = [0.1, 0.2, 0.3, 1]
        let again = try JSONDecoder().decode(WidgetSnapshot.self, from: JSONEncoder().encode(written))
        #expect(again.coverTint == [0.1, 0.2, 0.3, 1])
    }

    @Test("the app puts the colour into the snapshot when writing the cover, the widget computes nothing", .needsTheSources)
    func theAppWritesTheColour() throws {
        let writer = try FetchAnswerTests.squeezedSource("Sources/ViewModels/PlayerViewModel+Widget.swift")
        #expect(writer.contains("if Self.lastWidgetCoverItemId == item.id { snapshot.coverTint = Self.lastWidgetCoverTint }"),
                "a new snapshot of the same title loses the colour")
        #expect(writer.contains("lastWidgetCoverTint = CoverColorLoader.bottomComponents(of: image)"))
        #expect(writer.contains("saved.coverTint = lastWidgetCoverTint saved.save()"), "the saved snapshot does not learn the colour")
        let widget = try FetchAnswerTests.squeezedSource("LiveActivityWidget/ContinueListeningWidget.swift")
        #expect(widget.contains("entry.snapshot?.coverTint.flatMap(Self.color(of:))"), "the widget's gradient ignores the colour")
        #expect(!widget.contains("bottomComponents"), "the widget computes the colour itself")
        #expect(widget.contains(".frame(height: space.size.height * 0.75) .overlay(alignment: .top) { coverImage } .clipped()"),
                "the cover no longer takes three quarters of the small widget, closed with its top edge")
        #expect(widget.contains(".overlay { coverWithBand }"), "the playing half lays its text over the cover again")
        let player = try FetchAnswerTests.squeezedSource("Sources/ViewModels/PlayerViewModel+NowPlaying.swift")
        #expect(player.contains("if self.item?.id == stationID { self.refreshSharedCover(from: image) }"),
                "the widget gets a station's favicon instead of the picture the player shows")
    }
}
#endif
