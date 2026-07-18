import SwiftUI

/// Shared badge family for cover surfaces (S11c/S14c). The offline (wifi.slash)
/// badge and the download install ring form ONE family: both sit at the cover's
/// BOTTOM-RIGHT, sized proportionally to the tile — 22 % of its width, clamped
/// to [18, 44] pt — so every cover (grid cell, featured card, row, music) reads
/// the same. Use `CoverBadge.size(tileWidth:)` for the edge length.
enum CoverBadge {
    /// Badge edge length for a given cover/tile width: 22 % of the width, clamped
    /// to a legible-but-not-huge [18, `cap`] pt. `cap` defaults to 44 (grid
    /// tiles); the wide FeaturedCards pass a smaller cap (X6c) — 22 % of a 235 pt
    /// card is ~52 pt and hit the 44 pt cap, which read as too fat.
    static func size(tileWidth: CGFloat, cap: CGFloat = 44) -> CGFloat {
        min(max(tileWidth * 0.22, 18), cap)
    }
}
