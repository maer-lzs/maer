import SwiftUI

/// Shared badge family for cover surfaces (S11c/S14c). The offline (wifi.slash)
/// badge and the download install ring form ONE family: both sit at the cover's
/// BOTTOM-RIGHT, sized proportionally to the tile — 22 % of its width, clamped
/// to [18, 44] pt — so every cover (grid cell, featured card, row, music) reads
/// the same. Use `CoverBadge.size(tileWidth:)` for the edge length.
enum CoverBadge {
    /// X6d: size REFERENCE of the whole family — the detail pages' status/
    /// download controls (glass-capsule buttons, 44 pt hit areas on both the
    /// book and the podcast-episode page) use it directly, and no cover badge
    /// grows past it. One source across all media tabs.
    static let detailControl: CGFloat = 44

    /// Badge edge length for a given cover/tile width: 22 % of the width (the
    /// small-tile scaling), clamped to a legible-but-not-huge [18, `cap`] pt.
    /// `cap` defaults to the detail-control reference (grid tiles); the wide
    /// FeaturedCards pass a smaller cap (X6c) — 22 % of a 235 pt card is ~52 pt
    /// and hit the 44 pt cap, which read as too fat.
    static func size(tileWidth: CGFloat, cap: CGFloat = detailControl) -> CGFloat {
        min(max(tileWidth * 0.22, 18), cap)
    }
}
