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
}
#endif
