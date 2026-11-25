// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import SwiftUI

/// Shared badge family for cover surfaces. The offline (wifi.slash)
/// disc sits at the tile's TOP-RIGHT so it never collides with the
/// bottom-right corner control (play badge, subscribe plus); the download
/// install ring keeps the bottom-right. The offline disc is a FIXED,
/// type-scaled size matching the corner play glyph (`OfflineUnavailableBadge`);
/// the install ring still scales with the tile via `CoverBadge.size(tileWidth:)`
/// (22 % of the width, clamped [18, 44] pt).
enum CoverBadge {
    /// The family's HIT-TARGET constant (44 pt). The detail pages'
    /// status/download controls size their buttons with it, `CardDownloadBadge`
    /// uses it for its tap frame, and `size(tileWidth:)` caps at it. The card
    /// badge's VISIBLE size follows the card's info pill instead.
    static let detailControl: CGFloat = 44

    /// Badge edge length for a given cover/tile width: 22 % of the width (the
    /// small-tile scaling), clamped to a legible-but-not-huge [18, `cap`] pt.
    /// `cap` defaults to the detail-control reference.
    static func size(tileWidth: CGFloat, cap: CGFloat = detailControl) -> CGFloat {
        min(max(tileWidth * 0.22, 18), cap)
    }
}

/// THE size of the marks on a cover, one per class of cover, so the marks
/// of one cover stand equal: a tile's stack (kind, lock, availability,
/// finished, favourite, count) and a row's two marks. The downloaded mark
/// of a tile stood at 30 pt among marks of 22 and covered the title
/// printed on the cover. Grows with the text: a tile's marks up to the
/// first accessibility size (measured at AX3, a 150 pt tile held one
/// grown mark above its control), a row's up to 24 pt (an uncapped mark
/// hid half of a row's cover).
enum CoverMarkSize {
    enum Class {
        /// The stack at the top right of a tile or card.
        case tile
        /// The cover of a list row.
        case row
        /// The downloaded state in an episode row's column of controls,
        /// beside the 44 pt controls; not on a cover.
        case control
    }

    static func diameter(_ kind: Class, _ size: DynamicTypeSize) -> CGFloat {
        switch kind {
        case .tile: scaled(22, .title3, min(size, .accessibility1))
        case .row: min(scaled(18, .caption1, size), 24)
        case .control: min(scaled(30, .title3, size), CoverBadge.detailControl)
        }
    }

    /// The distance of a mark from the cover's edge.
    static func inset(_ kind: Class) -> CGFloat {
        switch kind {
        case .tile: 5
        case .row: 2
        case .control: 0
        }
    }

    private static func scaled(_ value: CGFloat, _ style: UIFont.TextStyle, _ size: DynamicTypeSize) -> CGFloat {
        let traits = UITraitCollection(preferredContentSizeCategory: UIContentSizeCategory(size))
        return UIFontMetrics(forTextStyle: style).scaledValue(for: value, compatibleWith: traits).rounded()
    }
}

/// THE offline disc. A white wifi.slash on the disc of the tone, sized to
/// MATCH the corner play glyph (`MediaTilePlayBadge`) so the two
/// corner marks read equal on every tile; scales with Dynamic Type like the
/// play glyph. Every tile draws it in its stack of marks (`CoverGlyphStack`).
struct OfflineUnavailableBadge: View {
    var size: CoverMarkSize.Class = .tile
    @Environment(\.dynamicTypeSize) private var type

    var body: some View {
        let diameter = CoverMarkSize.diameter(size, type)
        Image(systemName: "wifi.slash")
            .font(.system(size: diameter * 0.5, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: diameter, height: diameter)
            .glyphDisc()
            // The disc is the state; VoiceOver hears it as such.
            .accessibilityLabel(Text("Not available offline"))
    }
}

/// THE downloaded mark: this is on the device. One component for every place
/// that says so, drawn only when it is true, never as an offer to download.
/// A white arrow on the disc of the tone the other marks wear (the symbol's
/// circle layer stays clear over it), never a grey glyph lost in the page.
/// It grows with the text.
///
/// The symbol is ONE constant. Its form is a product decision; a change of
/// form is this line and nothing else.
struct DownloadedMark: View {
    static let symbol = "arrow.down.circle.fill"

    /// The class of cover it stands on; its size is the class's
    /// (`CoverMarkSize`), as large as every other mark there.
    let size: CoverMarkSize.Class
    @Environment(\.dynamicTypeSize) private var type

    var body: some View {
        let diameter = CoverMarkSize.diameter(size, type)
        Image(systemName: Self.symbol)
            .font(.system(size: diameter))
            .frame(width: diameter, height: diameter)
            .symbolRenderingMode(.palette)
            .foregroundStyle(.white, .clear)
            .glyphDisc()
            .accessibilityElement()
            .accessibilityLabel(Text("Downloaded"))
    }
}
