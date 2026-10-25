// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import SwiftUI
@testable import Maer

/// The full player's ground reaches every corner of the display at rest.
/// The glass sheet keeps one constant radius, so on a display with square
/// corners (the hinge side of a foldable, an iPad) the library shone through
/// beside the rounding. `SheetCorners` fills exactly that.
struct SheetCornersTests {
    private let rect = CGRect(x: 0, y: 0, width: 400, height: 800)

    /// Whether the even-odd fill covers a point, asked of Core Graphics.
    /// SwiftUI's `Path.contains(_:eoFill:)` answers points inside the sheet
    /// as covered on iOS 18 while the drawn fill leaves them empty there too;
    /// the Core Graphics rule matches the drawing on every system.
    private func covers(_ path: Path, _ point: CGPoint) -> Bool {
        path.cgPath.contains(point, using: .evenOdd)
    }

    @Test("the shape covers the four corners outside the rounding and nothing inside")
    func coversOnlyTheOpenCorners() {
        let path = SheetCorners(radius: 28).path(in: rect)
        for corner in [CGPoint(x: 1, y: 1), CGPoint(x: 399, y: 1), CGPoint(x: 1, y: 799), CGPoint(x: 399, y: 799)] {
            #expect(covers(path, corner), "corner \(corner) stays open")
        }
        for inside in [CGPoint(x: 200, y: 400), CGPoint(x: 30, y: 400), CGPoint(x: 200, y: 30), CGPoint(x: 28, y: 28)] {
            #expect(!covers(path, inside), "\(inside) lies inside the sheet")
        }
    }

    @Test("without a radius there is nothing to fill")
    func zeroRadiusFillsNothing() {
        let path = SheetCorners(radius: 0).path(in: rect)
        #expect(!covers(path, CGPoint(x: 1, y: 1)))
        #expect(!covers(path, CGPoint(x: 200, y: 400)))
    }

    @Test("full at rest, gone a short way into the drag")
    func fadesWithTheDrag() {
        #expect(SheetCorners.opacity(dragProgress: SheetCorners.restReveal) == 1)
        #expect(SheetCorners.opacity(dragProgress: 0) == 1)
        let half = SheetCorners.opacity(dragProgress: SheetCorners.restReveal + SheetCorners.fadeSpan / 2)
        #expect(abs(half - 0.5) < 0.0001)
        #expect(SheetCorners.opacity(dragProgress: SheetCorners.restReveal + SheetCorners.fadeSpan) == 0)
        #expect(SheetCorners.opacity(dragProgress: 1) == 0)
    }

    /// The fence: the player's ground draws the corners, and the overlay's
    /// rest reveal is the one value the corners fade from, not a second literal.
    @Test("the player ground draws the corners and the overlay rests on the shared reveal")
    func playerUsesTheCorners() throws {
        let views = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/Views")
        let player = try String(contentsOf: views.appendingPathComponent("PlayerView.swift"), encoding: .utf8)
        let overlay = try String(contentsOf: views.appendingPathComponent("FullPlayerOverlay.swift"), encoding: .utf8)
        #expect(player.contains("SheetCorners(radius: cornerRadius)"))
        #expect(player.contains("SheetCorners.opacity(dragProgress: dragProgress)"))
        #expect(overlay.contains("SheetCorners.restReveal + (1 - SheetCorners.restReveal)"))
        #expect(!overlay.contains("0.15 + 0.85"))
    }
}
#endif
