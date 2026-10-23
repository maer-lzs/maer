// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// The Continue Listening widget draws its cover to every edge in both
/// sizes: the cover is the widget's background, the text stands over it.
/// The widget target has no test host, so the fence reads its source.
struct ContinueListeningWidgetFenceTests {

    @Test("das Widget Weiterhoeren zeichnet das Cover in beiden Groessen bis an den Rand, der Text steht darueber", .needsTheSources)
    func theCoverReachesEveryEdge() throws {
        let widget = try FetchAnswerTests.squeezedSource("LiveActivityWidget/ContinueListeningWidget.swift")
        #expect(widget.contains(".containerBackground(for: .widget) { if entry.snapshot != nil { coverBackground } else {"),
                "a size draws its cover inside the system's margins again")
        #expect(!widget.contains("family == .systemSmall, entry.snapshot != nil"), "only the small widget carries the cover")
        #expect(!widget.contains(".frame(width: 96, height: 96)"), "the medium widget shows a small cover beside the text again")
        let medium = try #require(widget.range(of: "private func medium(")).upperBound
        let body = String(widget[medium...].prefix(900))
        #expect(body.contains(".foregroundStyle(.white)") && body.contains("alignment: .bottomLeading)"),
                "the medium text no longer stands white at the bottom over the cover")
    }
}
#endif
