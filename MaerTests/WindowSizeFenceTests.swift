// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// A layout reads the size its window gives it, never the kind of device or
/// the size of the screen: the iPhone Duo is a phone as short as a phone when
/// folded and as wide as a small iPad when open, and a split window is
/// narrower than its screen.
struct WindowSizeFenceTests {

    /// The questions a layout must not ask, as their call reads.
    static let deviceQuestions = ["userInterfaceIdiom", "UIScreen.main", ".screen.bounds", "screen?.bounds"]

    /// Where `code` asks one of them, comment lines cut away.
    static func asks(_ code: String) -> [String] {
        SyncContractFenceTests.stripped(code).split(separator: "\n").compactMap { line in
            Self.deviceQuestions.contains { line.contains($0) } ? line.trimmingCharacters(in: .whitespaces) : nil
        }
    }

    @Test("the counter sees every question about device and screen, none in a comment")
    func theCounterReads() {
        #expect(Self.asks("let p = UIDevice.current.userInterfaceIdiom == .phone").count == 1)
        #expect(Self.asks("let w = UIScreen.main.bounds.width").count == 1)
        #expect(Self.asks("let w = scene.screen.bounds.width").count == 1)
        #expect(Self.asks("return screen?.bounds.width ?? 400").count == 1)
        #expect(Self.asks("// not UIScreen.main, not userInterfaceIdiom").isEmpty)
        #expect(Self.asks("let w = geo.size.width").isEmpty)
    }

    @Test("no view asks about device or screen", .needsTheSources)
    func noLayoutAsksTheDevice() throws {
        var found: [String] = []
        let files = ProjectFileIntegrityTests.sourceFiles()
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            found += Self.asks(text).map { "\(file.lastPathComponent): \($0)" }
        }
        #expect(files.count > 100, "the fence read the sources")
        #expect(found.isEmpty, "a layout asks the device or the screen instead of its window: \(found)")
    }

    @Test("the book page fills the height tightly only where it is short")
    func theBookPageDecidesByItsHeight() {
        // A phone on its side and the folded Duo on its side.
        #expect(BookDetailCover.sharpFills(height: 390))
        #expect(BookDetailCover.sharpFills(height: 440))
        #expect(BookDetailCover.sharpFills(height: 466))
        // The open Duo on its side and an iPad mini on its side.
        #expect(!BookDetailCover.sharpFills(height: 669))
        #expect(!BookDetailCover.sharpFills(height: 744))
    }
}
#endif
