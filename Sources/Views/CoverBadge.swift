// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

/// Shared badge family for cover surfaces (S11c/S14c). The offline (wifi.slash)
/// disc sits at the tile's TOP-RIGHT (Y44) so it never collides with the
/// bottom-right corner control (play badge, subscribe plus); the download
/// install ring keeps the bottom-right. Y54: the offline disc is a FIXED,
/// type-scaled size matching the corner play glyph (`OfflineUnavailableBadge`);
/// the install ring still scales with the tile via `CoverBadge.size(tileWidth:)`
/// (22 % of the width, clamped [18, 44] pt).
enum CoverBadge {
    /// X6d/X6f: the family's HIT-TARGET constant (44 pt) — the detail pages'
    /// status/download controls size their buttons with it, `CardDownloadBadge`
    /// uses it for its tap frame, and `size(tileWidth:)` caps at it. The card
    /// badge's VISIBLE size follows the card's info pill instead (X6f).
    static let detailControl: CGFloat = 44

    /// Badge edge length for a given cover/tile width: 22 % of the width (the
    /// small-tile scaling), clamped to a legible-but-not-huge [18, `cap`] pt.
    /// `cap` defaults to the detail-control reference.
    static func size(tileWidth: CGFloat, cap: CGFloat = detailControl) -> CGFloat {
        min(max(tileWidth * 0.22, 18), cap)
    }
}

/// A3/Y54: THE offline disc — a white wifi.slash on a dark circle, sized to
/// MATCH the corner play glyph (`play.circle.fill` at `.title3`) so the two
/// corner marks read equal on every tile; scales with Dynamic Type like the
/// play glyph. Used by the `offlineUnavailableBadge` modifier and inline where a
/// surface can't take the modifier (BookCoverView's finished-state interplay).
struct OfflineUnavailableBadge: View {
    @ScaledMetric(relativeTo: .title3) private var diameter: CGFloat = 22

    var body: some View {
        Image(systemName: "wifi.slash")
            .font(.system(size: diameter * 0.5, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: diameter, height: diameter)
            .background(.black.opacity(0.45), in: Circle())
    }
}

extension View {
    /// A3 (rule): gray/dimming is NEVER the only state carrier — unavailable
    /// content dims AND carries the white wifi.slash badge. Y44: TOP-RIGHT so it
    /// clears the bottom-right corner control (play badge, subscribe plus). Y54:
    /// the disc matches the play glyph's size (see `OfflineUnavailableBadge`).
    @ViewBuilder
    func offlineUnavailableBadge(_ active: Bool) -> some View {
        if active {
            self.opacity(0.5)
                .overlay(alignment: .topTrailing) {
                    OfflineUnavailableBadge().padding(5)
                }
        } else {
            self
        }
    }
}
