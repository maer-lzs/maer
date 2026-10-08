// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import SwiftUI

/// THE label of a list row at an accessibility text size: symbol and title
/// side by side, so a title that wraps keeps its own edge. The system's
/// label in a list lets the wrapped title flow under the symbol at those
/// sizes, while the row's separator stays at the edge of the title's first
/// line (measured at AX3 in the settings and on the statistics page). At
/// every other size it is the system's label, unchanged.
///
/// A `Toggle` does not hand a style from outside to its label, so
/// `AppSwitch` sets it on its own label; `HintLine` sets it on its own.
struct RowLabelStyle: LabelStyle {
    func makeBody(configuration: LabelStyleConfiguration) -> some View {
        RowLabel(configuration: configuration)
    }

    private struct RowLabel: View {
        let configuration: LabelStyleConfiguration
        @Environment(\.dynamicTypeSize) private var typeSize
        /// The symbol column: one width for every row, so the titles of a
        /// list share one edge whatever their symbol's own width (the
        /// system's label keeps such a column too).
        @ScaledMetric(relativeTo: .body) private var column: CGFloat = 27.5

        var body: some View {
            if typeSize.isAccessibilitySize {
                HStack(alignment: .firstTextBaseline) {
                    configuration.icon.frame(width: column)
                    configuration.title
                }
            } else {
                Label(configuration)
            }
        }
    }
}
