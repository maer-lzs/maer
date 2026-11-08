// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// The Continue Listening widget draws its cover to every edge in both
/// home sizes while it shows its one title: the cover is the widget's
/// background, the text stands over it. The rows of the large and medium
/// widget and the two lock screen families go without, since the lock
/// screen draws in one tone. The widget target has no test host, so the
/// fence reads its source.
struct ContinueListeningWidgetFenceTests {

    @Test("das Widget Weiterhoeren zeichnet das Cover in beiden Groessen bis an den Rand, der Text steht darueber", .needsTheSources)
    func theCoverReachesEveryEdge() throws {
        let widget = try FetchAnswerTests.squeezedSource("LiveActivityWidget/ContinueListeningWidget.swift")
        #expect(widget.contains(".containerBackground(for: .widget) { if isAccessory { Color.clear } else if face == .oneTitle { coverBackground } else {"),
                "a size draws its cover inside the system's margins again")
        #expect(widget.contains("private var isAccessory: Bool { family == .accessoryRectangular || family == .accessoryCircular }"),
                "a home size counts as a lock screen family and loses its cover")
        #expect(!widget.contains("family == .systemSmall, entry.snapshot != nil"), "only the small widget carries the cover")
        #expect(!widget.contains(".frame(width: 96, height: 96)"), "the medium widget shows a small cover beside the text again")
        let medium = try #require(widget.range(of: "private func medium(")).upperBound
        let body = String(widget[medium...].prefix(900))
        #expect(body.contains(".foregroundStyle(.white)") && body.contains("alignment: .bottomLeading)"),
                "the medium text no longer stands white at the bottom over the cover")
    }

    @Test("die Zeilen teilen sich die ganze Hoehe unter der Ueberschrift, das Cover waechst quadratisch mit der Zeile", .needsTheSources)
    func theRowsShareTheWholeHeight() throws {
        let widget = try FetchAnswerTests.squeezedSource("LiveActivityWidget/ContinueListeningWidget.swift")
        let start = try #require(widget.range(of: "private func rowsFace(")).upperBound
        let rest = widget[start...]
        let face = String(rest[..<(rest.range(of: " private func ")?.lowerBound ?? rest.endIndex)])
        #expect(face.contains("let height = WidgetRows.rowHeight(available: space.size.height, rows: rows.count, spacing: spacing)"),
                "the rows no longer share the height under the heading")
        #expect(face.contains("sourceRow(row, coverSide: side) .frame(height: height)"), "a row keeps only its own height")
        #expect(face.contains("min(height, family == .systemLarge ? 140 : 96)"), "the cover no longer grows with its row")
        #expect(!face.contains("Spacer("), "the rows stand at the top and leave the bottom empty")
        #expect(!widget.contains("rowCover(row, side:"), "the row's cover has a fixed side again")
        #expect(WidgetRows.rowHeight(available: 300, rows: 4, spacing: 12) == 66)
        #expect(WidgetRows.rowHeight(available: 120, rows: 1, spacing: 8) == 120)
        #expect(WidgetRows.rowHeight(available: 100, rows: 0, spacing: 8) == 0)
    }

    private static func row(_ id: String, _ source: WidgetSource, at playedAt: Double) -> WidgetSourceRow {
        WidgetSourceRow(source: source, itemId: id, title: id, subtitle: nil, fraction: 0.5, remainingText: nil,
                        isLive: false, kindSymbol: "book", cover: nil, playedAt: playedAt)
    }

    @Test("mittel waehrend der Wiedergabe: links der laufende Titel, rechts die Zeilen ohne ihn; sonst die ganze Breite")
    func theMediumSplitsWhilePlaying() {
        let rows = [Self.row("playing", .audiobooks, at: 3), Self.row("episode", .podcasts, at: 2),
                    Self.row("album", .music, at: 1)]
        let beside = WidgetRows.besidePlaying(rows, playing: "playing", layout: .mediumRecent, accessibilitySize: false)
        #expect(beside.map(\.itemId) == ["episode", "album"], "the right half: \(beside.map(\.itemId))")
        #expect(WidgetRows.splitsWhilePlaying(isMedium: true, isPlaying: true, accessibilitySize: false, besideCount: 2))
        #expect(!WidgetRows.splitsWhilePlaying(isMedium: true, isPlaying: false, accessibilitySize: false, besideCount: 2),
                "without playback the rows keep the whole width")
        #expect(!WidgetRows.splitsWhilePlaying(isMedium: false, isPlaying: true, accessibilitySize: false, besideCount: 2))
        #expect(!WidgetRows.splitsWhilePlaying(isMedium: true, isPlaying: true, accessibilitySize: true, besideCount: 2))
        #expect(!WidgetRows.splitsWhilePlaying(isMedium: true, isPlaying: true, accessibilitySize: false, besideCount: 0),
                "nothing beside the title: the one face")
    }

    @Test("das Widget fragt die Regel der Teilung und zeichnet links den Titel, rechts die Zeilen", .needsTheSources)
    func theWidgetDrawsTheSplit() throws {
        let widget = try FetchAnswerTests.squeezedSource("LiveActivityWidget/ContinueListeningWidget.swift")
        #expect(widget.contains("if let split = playingSplit { HStack(spacing: 12) { playingHalf(split.snapshot) rowsFace(split.beside, covers: false) } }"))
        #expect(widget.contains("guard WidgetRows.splitsWhilePlaying(isMedium: family == .systemMedium, isPlaying: snapshot.isPlaying,"))
    }
}
#endif
