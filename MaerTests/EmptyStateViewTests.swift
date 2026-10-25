// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Foundation
import SwiftUI
import Testing
@testable import Maer

/// An empty state wraps in a narrow column instead of ending in an
/// ellipsis. The witness is the rendered height at the column widths of the
/// fold (closed about 380, one column of the open fold between 330 and 450)
/// with the German heading of a playlist that could not load. The counter
/// probe shows the measure sees a cut: the bare `ContentUnavailableView`
/// under a container's line limit renders lower, its heading ends in dots.
@MainActor
struct EmptyStateViewTests {
    private static let widths: [CGFloat] = [330, 380, 450]

    private func height(_ view: some View, width: CGFloat) -> CGFloat {
        let renderer = ImageRenderer(content: view
            .environment(\.locale, Locale(identifier: "de"))
            .frame(width: width))
        renderer.scale = 2
        return renderer.uiImage?.size.height ?? 0
    }

    private var failedPlaylist: some View {
        EmptyStateView("Couldn't load tracks", systemImage: "music.note",
                       description: Text("The source did not answer."))
    }

    @Test("Die Ueberschrift bricht bei 330, 380 und 450 pt um, auch unter einer Zeilengrenze des Behaelters")
    func theTitleWrapsInANarrowColumn() {
        for width in Self.widths {
            let free = height(failedPlaylist, width: width)
            #expect(free > 0, "nothing rendered at \(width)")
            #expect(height(failedPlaylist.lineLimit(1), width: width) == free,
                    "the title is cut at \(width) pt under a container line limit")
        }
        // At 330 and 380 the heading takes two lines: higher than the same
        // state with a short one.
        let short = EmptyStateView("No tracks", systemImage: "music.note",
                                   description: Text("The source did not answer."))
        for width in Self.widths.prefix(2) {
            #expect(height(failedPlaylist, width: width) > height(short, width: width),
                    "the long title stands on one line at \(width) pt")
        }
    }

    @Test("Gegenprobe: das nackte ContentUnavailableView kuerzt unter derselben Grenze")
    func theBareSystemViewIsCut() {
        let bare = ContentUnavailableView {
            Label("Couldn't load tracks", systemImage: "music.note")
        } description: {
            Text("The source did not answer.")
        }
        #expect(height(bare.lineLimit(1), width: 330) < height(failedPlaylist, width: 330))
    }

    @Test("Jeder Leerzustand der App geht ueber EmptyStateView", .needsTheSources)
    func everyEmptyStateGoesThroughTheOneView() throws {
        var direct: [String] = []
        for file in SourceTree.files(under: SourceTree.root.appendingPathComponent("Sources"))
        where file.pathExtension == "swift" && file.lastPathComponent != "EmptyStateView.swift" {
            let text = try String(contentsOf: file, encoding: .utf8)
            if SearchDoorFenceTests.code(in: text).contains("ContentUnavailableView") {
                direct.append(SourceTree.relativePath(of: file))
            }
        }
        #expect(direct.isEmpty, "draws the system view directly: \(direct)")
        // Red probe: the check sees a use, and not a comment.
        #expect(SearchDoorFenceTests.code(in: "ContentUnavailableView(\"x\", systemImage: \"y\")")
            .contains("ContentUnavailableView"))
        #expect(!SearchDoorFenceTests.code(in: "// a ContentUnavailableView").contains("ContentUnavailableView"))
    }
}
#endif
