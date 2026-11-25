// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Foundation
import Testing
@testable import Maer

/// The two marks that say something went wrong share one colour, from one
/// place: a download that failed and a feed that refused access.
struct FailedMarkToneTests {
    @Test("Fence: the failed download and the refused feed both wear GlyphTone.alert, and no mark names the colour itself", .needsTheSources)
    func oneAlertTone() throws {
        func source(_ path: String) throws -> String {
            SyncContractFenceTests.stripped(try String(contentsOf: SourceTree.root.appendingPathComponent(path), encoding: .utf8))
        }
        let stack = try source("Sources/Views/CoverGlyphStack.swift")
        let lock = try source("Sources/Views/Podcasts/PremiumBadge.swift")
        #expect(stack.contains("static let alert = Color.orange"), "the alert tone has no place of its own")
        #expect(stack.contains(".background(Circle().fill(GlyphTone.alert))"), "the failed download keeps another colour")
        #expect(lock.contains(".background(Circle().fill(GlyphTone.alert))"), "the refused feed keeps its own colour")
        #expect(!lock.contains("Color.orange") && !stack.contains("Circle().fill(AppTheme.accent)"))
    }
}
#endif
