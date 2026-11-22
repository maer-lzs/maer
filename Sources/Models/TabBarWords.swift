// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import CoreGraphics

/// Whether a tab of the bar shows its word, and where.
nonisolated enum TabBarWords {
    enum Form: Equatable {
        case symbol
        case wordBelow
        case wordBeside
    }

    /// The switch's value on a device that never set it.
    static let defaultOn = false

    /// The last rung of the bar's ladder: the symbols alone.
    static let symbolRung: CGFloat = 0

    static func form(wordFits: Bool, accessibilitySize: Bool, wordsOn: Bool, landscape: Bool) -> Form {
        .symbol
    }

    static func rungs(_ wordSizes: [CGFloat], accessibilitySize: Bool, wordsOn: Bool) -> [CGFloat] {
        [symbolRung]
    }
}
