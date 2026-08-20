// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation
import UIKit

/// 59b320e: the tab bar's label scale, and the ONE capsule metric both bars
/// share.
///
/// Measured first, as the order asked: the squeeze is OURS, not the system's.
/// `MediaTabBar` carried `.minimumScaleFactor(0.8)` on the label, and SwiftUI
/// applies that PER TEXT — so only the longest title shrinks. With five tabs of
/// equal width, "Hörbücher" was the only one to hit the floor and stood visibly
/// smaller than its four neighbours. It does not depend on being active: the
/// cell width does not change with selection (the pill is a background), so the
/// cause is length alone.
///
/// the owner's own measurement — four tabs normal, five squeezed — fits this
/// exactly, and it does NOT argue for the system bar: `minimumScaleFactor` is
/// not a constant shrink, it is a shrink that starts when the text stops
/// fitting. Four tabs give each cell more width and "Hörbücher" fits; the fifth
/// takes that width away. Same trigger, our mechanism.
///
/// The defect the owner named is therefore the INEQUALITY, not the smallness —
/// "Hörbücher ist kleiner als der Rest". So the scale is computed ONCE for the
/// whole row and applied to EVERY label: they may all be a little smaller
/// together, but none stands out. No title is shortened (that is his call,
/// deliberately not ours) and nothing is truncated.
nonisolated enum TabBarMetrics {
    /// How small a label may get before we stop. Below this the bar would read
    /// smaller than the rest of the interface, which is the defect one layer
    /// down.
    static let minimumScale: CGFloat = 0.8

    /// ONE scale for the whole row: the tightest fit any single label needs,
    /// clamped to the floor and never above 1 (a short row does not grow).
    ///
    /// `widths` are the labels' natural widths at the unscaled font, `available`
    /// is the width ONE cell offers after its padding.
    static func uniformScale(labelWidths widths: [CGFloat], available: CGFloat) -> CGFloat {
        guard available > 0, let widest = widths.max(), widest > 0 else { return 1 }
        return min(1, max(minimumScale, available / widest))
    }

    /// The natural width of a label at a given font — the input the uniform
    /// scale is derived from. Kept here so the rule and its measurement live in
    /// one place, and so a test can compute the same number the view does.
    static func labelWidth(_ text: String, font: UIFont) -> CGFloat {
        (text as NSString).size(withAttributes: [.font: font]).width
    }

    /// 98c621f: the ONE capsule metric — the tab bar's active pill and the
    /// settings tabs' chips share it.
    ///
    /// The growth goes into the HEIGHT only. the owner asked for bigger capsules
    /// while the same bar has a title that already does not fit: extra width
    /// would take exactly the room "Hörbücher" is missing, and the two orders
    /// would cancel each other out.
    enum Capsule {
        /// Vertical inset of the label inside its capsule — this is what grew.
        static let verticalPadding: CGFloat = 11
        /// Unchanged on purpose. May never fall below this.
        static let horizontalPadding: CGFloat = 8
        /// The value before 98c621f, kept so the fence can state the change
        /// instead of describing it.
        static let previousVerticalPadding: CGFloat = 8
    }
}
