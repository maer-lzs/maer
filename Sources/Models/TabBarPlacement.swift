// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation

/// The side at which the system stands its own bars upright (iOS 27.1
/// `toolbarVerticalEdge`): today only a folded iPhone Duo reports one.
nonisolated enum VerticalBarSide: Equatable, Sendable {
    case leading, trailing
}

/// Where the tab bar stands. It follows the system's own bars, never the
/// size or the kind of device: where the system stands its bars upright,
/// ours stands upright at the same edge, in the column under the status
/// bar; everywhere else it stays at the bottom. The system has no way to
/// move a tab bar of our own, so this rule does it.
nonisolated enum TabBarPlacement: Equatable, Sendable {
    case bottom
    case side(VerticalBarSide)

    static func of(verticalBarSide: VerticalBarSide?) -> TabBarPlacement {
        verticalBarSide.map(TabBarPlacement.side) ?? .bottom
    }

    var isSide: Bool { self != .bottom }
}

/// The axis of the glyphs in the system's upright status column (clock,
/// Wi-Fi): the middle of the column without its margin at the window's
/// edge. Measured on the iPhone Duo: column 84 pt, glyphs at its leading edge
/// plus 36.1 folded and 36.7 open on its side; the camera lay on the axis
/// folded only by chance and on its side sits outside the column.
nonisolated enum StatusColumnAxis {
    /// The column's margin at the window's edge, which its glyphs leave out.
    static let edgeMargin: CGFloat = 12

    static func x(columnMinX: CGFloat, columnWidth: CGFloat) -> CGFloat {
        columnMinX + (columnWidth - edgeMargin) / 2
    }
}
