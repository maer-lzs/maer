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
/// ellipsis, at the column widths of the fold (closed about 380, one column
/// of the open fold between 330 and 450), with the German heading of a
/// playlist that could not load. Two ways cut the bare
/// `ContentUnavailableView`, and the witness measures both: in a list row
/// on iOS 27 it draws its heading in one line's height whatever the line
/// limit (measured as the ink of the drawn row), and on iOS 18 a line limit
/// of the container reaches its heading (measured as rendered height). The
/// counter probe shows the measure of the running system sees its cut.
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

    /// The view as the one row of a plain list in a window of `width`,
    /// drawn, and the number of pixel rows that hold black: the heading's
    /// ink, as the other texts are grey.
    private func headingInk(_ row: some View, width: CGFloat) async throws -> Int {
        let list = List { row }
            .listStyle(.plain)
            .environment(\.locale, Locale(identifier: "de"))
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        let window = scene.map { UIWindow(windowScene: $0) } ?? UIWindow()
        window.frame = CGRect(x: 0, y: 0, width: width, height: 600)
        window.rootViewController = UIHostingController(rootView: list)
        window.isHidden = false
        defer { window.isHidden = true }
        for _ in 0..<10 {
            try await Task.sleep(nanoseconds: 50_000_000)
            window.layoutIfNeeded()
        }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.preferredRange = .standard
        let image = UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        let cg = try #require(image.cgImage)
        let data = try #require(cg.dataProvider?.data)
        let bytes = try #require(CFDataGetBytePtr(data))
        let stride = cg.bytesPerRow, pixel = cg.bitsPerPixel / 8
        var rows = 0
        for y in 0..<cg.height {
            for x in 0..<cg.width {
                let at = y * stride + x * pixel
                // Black in any byte order: three of the four bytes near zero.
                if (0..<pixel).filter({ bytes[at + $0] < 30 }).count >= 3 {
                    rows += 1
                    break
                }
            }
        }
        return rows
    }

    private var failedPlaylist: some View {
        EmptyStateView("Couldn't load tracks", systemImage: "music.note",
                       description: Text("The source did not answer."))
    }

    private var shortHeading: some View {
        EmptyStateView("No tracks", systemImage: "music.note",
                       description: Text("The source did not answer."))
    }

    private var bare: some View {
        ContentUnavailableView {
            Label("Couldn't load tracks", systemImage: "music.note")
        } description: {
            Text("The source did not answer.")
        }
    }

    @Test("In einer Listenzeile steht die Ueberschrift bei 330 und 380 pt in zwei Zeilen, bei 450 in einer")
    func theHeadingWrapsInAListRow() async throws {
        for width in Self.widths {
            let long = try await headingInk(failedPlaylist, width: width)
            let short = try await headingInk(shortHeading, width: width)
            #expect(short > 0, "nothing drawn at \(width)")
            if width < 450 {
                #expect(Double(long) > 1.5 * Double(short), "the heading stands on one line at \(width) pt")
            } else {
                #expect(long >= short)
            }
        }
    }

    @Test("Unter einer Zeilengrenze des Behaelters bleibt die Ueberschrift so hoch wie frei")
    func aContainerLineLimitDoesNotReachTheHeading() {
        for width in Self.widths {
            let free = height(failedPlaylist, width: width)
            #expect(free > 0, "nothing rendered at \(width)")
            #expect(height(failedPlaylist.lineLimit(1), width: width) == free,
                    "the heading is cut at \(width) pt under a container line limit")
        }
    }

    @Test("Gegenprobe: das nackte ContentUnavailableView kuerzt auf dem laufenden System")
    func theBareSystemViewIsCut() async throws {
        if #available(iOS 27, *) {
            #expect(try await headingInk(bare, width: 330) < headingInk(failedPlaylist, width: 330),
                    "the bare view wraps its heading in a list row")
        } else {
            #expect(height(bare.lineLimit(1), width: 330) < height(failedPlaylist, width: 330),
                    "the bare view keeps two lines under a container line limit")
        }
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
