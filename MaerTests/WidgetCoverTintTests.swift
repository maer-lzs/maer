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

    @Test("die Farbe kommt aus dem unteren Rand des Covers, abgedunkelt wie auf den Karten")
    func theColourIsTheBottomEdge() throws {
        let tint = try #require(CoverColorLoader.bottomComponents(of: Self.cover(top: .white, bottom: .red)))
        #expect(tint.count == 4)
        #expect(abs(tint[0] - 0.7) < 0.03 && tint[1] < 0.03 && tint[2] < 0.03, "not the darkened bottom red: \(tint)")
        let light = try #require(CoverColorLoader.bottomComponents(of: Self.cover(top: .black, bottom: .white)))
        #expect(light.prefix(3).allSatisfy { abs($0 - 0.7) < 0.03 }, "a light bottom is not darkened: \(light)")
    }

    @Test("ein Schnappschuss ohne Farbe liest sich, einer mit Farbe traegt sie")
    func aSnapshotWithoutTheColourReads() throws {
        let old = #"{"itemId":"a","title":"T","fraction":0.5,"isPlaying":false}"#
        let read = try JSONDecoder().decode(WidgetSnapshot.self, from: Data(old.utf8))
        #expect(read.coverTint == nil && read.title == "T")
        var written = read
        written.coverTint = [0.1, 0.2, 0.3, 1]
        let again = try JSONDecoder().decode(WidgetSnapshot.self, from: JSONEncoder().encode(written))
        #expect(again.coverTint == [0.1, 0.2, 0.3, 1])
    }

    @Test("die App legt die Farbe beim Schreiben des Covers in den Schnappschuss, das Widget rechnet nichts", .needsTheSources)
    func theAppWritesTheColour() throws {
        let writer = try FetchAnswerTests.squeezedSource("Sources/ViewModels/PlayerViewModel+Widget.swift")
        #expect(writer.contains("if Self.lastWidgetCoverItemId == item.id { snapshot.coverTint = Self.lastWidgetCoverTint }"),
                "a new snapshot of the same title loses the colour")
        #expect(writer.contains("lastWidgetCoverTint = CoverColorLoader.bottomComponents(of: image)"))
        #expect(writer.contains("saved.coverTint = lastWidgetCoverTint saved.save()"), "the saved snapshot does not learn the colour")
        let widget = try FetchAnswerTests.squeezedSource("LiveActivityWidget/ContinueListeningWidget.swift")
        #expect(widget.contains("entry.snapshot?.coverTint.flatMap(Self.color(of:))"), "the widget's gradient ignores the colour")
        #expect(!widget.contains("bottomComponents"), "the widget computes the colour itself")
    }
}
#endif
