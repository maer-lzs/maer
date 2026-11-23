// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Foundation
import Testing
@testable import Maer

/// The feature pages name the volume boost the app can give: its limit is
/// `SoundSetting.gainLimit` (twice the level, 6 dB). The 10 dB of
/// `boostCeilingDB` bound the preset and the boost together, not the boost.
struct SoundBoostDocsTests {
    @Test("the boost of the app is 6 dB, and both feature pages say so", .needsTheSources)
    func pagesNameTheBoost() throws {
        let decibels = Int((20 * log10(SoundSetting.gainLimit)).rounded())
        #expect(decibels == 6)
        for (path, words) in [("docs/features.md", "volume boost of up to \(decibels) dB"),
                              ("docs/features.de.md", "Verstärkung bis \(decibels) dB")] {
            let page = try String(contentsOf: SourceTree.root.appendingPathComponent(path), encoding: .utf8)
            #expect(page.contains(words), "\(path) does not name the boost the app gives")
            #expect(!page.contains("10 dB"), "\(path) still names 10 dB")
        }
    }
}
#endif
