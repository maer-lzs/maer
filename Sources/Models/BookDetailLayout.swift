// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation

/// Which form the book page takes, by the window it has, never by the kind
/// of device. A phone on its side (compact height) keeps the cover beside
/// the text; an upright window keeps the hero page; a window that is wide
/// and taller than a phone on its side (the open iPhone Duo, an iPad in
/// landscape) shows cover and facts in one column and the chapters in a
/// second one.
nonisolated enum BookDetailLayout: Equatable {
    case hero
    case sideBySide
    case twoColumns

    /// The open Duo on its side is 951 pt wide, an iPad in landscape wider;
    /// the folded Duo on its side (678 pt) stays under it.
    static let twoColumnsMinWidth: CGFloat = 700

    static func of(width: CGFloat, height: CGFloat, compactHeight: Bool) -> BookDetailLayout {
        if compactHeight { return .sideBySide }
        guard height > 0, width > height else { return .hero }
        return width >= twoColumnsMinWidth ? .twoColumns : .sideBySide
    }

    /// The left column of the two: cover and facts, the rest is the list.
    static func leftColumnWidth(total: CGFloat) -> CGFloat {
        min(460, max(320, total * 0.45))
    }
}
