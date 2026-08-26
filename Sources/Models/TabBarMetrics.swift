// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation

/// The ONE capsule metric. The tab bar's active pill and the settings
/// tabs' chips share it. One value, one place, no two numbers that drift apart.
///
/// What is deliberately NOT here any more: a computed label scale.
///
/// The first fix derived the tab-bar font size from an ESTIMATE of the
/// available width, and the estimate was wrong. The bar shares its row with
/// the search capsule, which the formula knew nothing about. The result was
/// worse than the defect it replaced ("Hörbüch…" instead of a small but whole
/// title). The bar now asks the LAYOUT which size fits (`ViewThatFits` over a
/// descending candidate list in `MediaTabBar`), so no number is left that can
/// drift away from the truth. A metric that has to guess at geometry is one
/// that will be wrong on the next screen size.
nonisolated enum TabBarMetrics {
    enum Capsule {
        /// Vertical inset of the label inside its capsule. This is what grew.
        static let verticalPadding: CGFloat = 11
        /// Unchanged on purpose: that width is exactly the room the longest
        /// title needs, and taking it would undo the other order.
        static let horizontalPadding: CGFloat = 8
        /// The previous value, kept so the fence can state the change
        /// instead of describing it.
        static let previousVerticalPadding: CGFloat = 8
    }
}
