// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import SwiftUI

/// b08c719 / 2c0a907: a row that WRAPS instead of squeezing.
///
/// the owner rejected the horizontal scroller, and his objection is the better
/// one: a scrolling row hides that there are five areas at all. In a navigation
/// whose job is to show the app's extent, that is the wrong trade.
///
/// So the chips flow: they stand in one line while they fit — on iPad, in
/// landscape, at small type — and the last one drops to a second line when they
/// do not. All of them stay visible, nothing scrolls, and because each chip is
/// single-line, no word can break inside one ("Allge-mein" becomes structurally
/// impossible rather than accidentally fixed).
///
/// The rule this layout must not violate: **the line count may depend on the
/// available width, never on which chip is active.** The bar sits at the very
/// top, so a height that changes on selection would push the whole page. That
/// holds here because the layout measures every subview at its ideal size and
/// the active chip carries no extra metric — the difference between active and
/// inactive is colour, not size.
nonisolated struct FlowLayout: Layout {
    var spacing: CGFloat = 8
    var lineSpacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        let rows = self.rows(for: subviews, width: width)
        let height = rows.reduce(0) { $0 + $1.height } + lineSpacing * CGFloat(max(0, rows.count - 1))
        let widest = rows.map(\.width).max() ?? 0
        return CGSize(width: proposal.width ?? widest, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize,
                       subviews: Subviews, cache: inout ()) {
        let rows = self.rows(for: subviews, width: bounds.width)
        var y = bounds.minY
        for row in rows {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y + (row.height - size.height) / 2),
                                      proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + lineSpacing
        }
    }

    private struct Row {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    /// Pure line breaking: fill a line while the next chip fits, then start a
    /// new one. A chip WIDER than the whole row still gets its own line rather
    /// than being squeezed — squeezing is what this exists to avoid.
    private func rows(for subviews: Subviews, width: CGFloat) -> [Row] {
        var rows: [Row] = []
        var current = Row()
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let needed = current.indices.isEmpty ? size.width : current.width + spacing + size.width
            if !current.indices.isEmpty, needed > width {
                rows.append(current)
                current = Row()
                current.indices = [index]
                current.width = size.width
                current.height = size.height
            } else {
                current.indices.append(index)
                current.width = needed
                current.height = max(current.height, size.height)
            }
        }
        if !current.indices.isEmpty { rows.append(current) }
        return rows
    }
}
