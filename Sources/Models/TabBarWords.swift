// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import CoreGraphics

/// Whether a tab of the bar shows its word, and where. The word stands
/// when it fits whole (the bar's ladder measures it), the text is below
/// the accessibility sizes and the switch under General is on; in
/// landscape it stands beside the symbol, so the bar keeps one line.
/// Otherwise the symbol stands alone, larger. The name stays for VoiceOver
/// in every form.
nonisolated enum TabBarWords {
    enum Form: Equatable {
        case symbol
        case wordBelow
        case wordBeside
    }

    /// The switch's value on a device that never set it.
    static let defaultOn = true

    /// The last rung of the bar's ladder: the symbols alone, which always
    /// fit.
    static let symbolRung: CGFloat = 0

    static func form(wordFits: Bool, accessibilitySize: Bool, wordsOn: Bool, landscape: Bool) -> Form {
        guard wordsOn, wordFits, !accessibilitySize else { return .symbol }
        return landscape ? .wordBeside : .wordBelow
    }

    /// The sizes the bar tries, largest first: the word sizes while words
    /// may stand, then the symbols alone.
    static func rungs(_ wordSizes: [CGFloat], accessibilitySize: Bool, wordsOn: Bool) -> [CGFloat] {
        (wordsOn && !accessibilitySize ? wordSizes : []) + [symbolRung]
    }
}
