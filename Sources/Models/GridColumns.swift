// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation

/// The columns of a grid whose cells take a width: as many columns of at
/// least `minimum` as fit, and each cell as wide as its column, so a cell
/// fills its column instead of standing in it with room on both sides.
nonisolated enum GridColumns {
    struct Layout: Equatable {
        let count: Int
        let width: Double
    }

    /// Below the width of one column (also before the page has measured
    /// itself) one column of the minimum width.
    static func layout(available: Double, minimum: Double, spacing: Double) -> Layout {
        guard minimum > 0, available >= minimum else { return Layout(count: 1, width: max(minimum, 0)) }
        let count = max(1, Int((available + spacing) / (minimum + spacing)))
        let width = ((available - spacing * Double(count - 1)) / Double(count)).rounded(.down)
        return Layout(count: count, width: width)
    }
}
