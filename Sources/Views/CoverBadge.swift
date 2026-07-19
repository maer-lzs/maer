import SwiftUI

/// Shared badge family for cover surfaces (S11c/S14c). The offline (wifi.slash)
/// disc sits at the tile's TOP-RIGHT (Y44) so it never collides with the
/// bottom-right corner control (play badge, subscribe plus); the download
/// install ring keeps the bottom-right. Both are sized proportionally to the
/// tile — 22 % of its width, clamped to [18, 44] pt — so every cover reads the
/// same. Use `CoverBadge.size(tileWidth:)` for the edge length.
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

extension View {
    /// A3 (rule): gray/dimming is NEVER the only state carrier — unavailable
    /// content dims AND carries the white wifi.slash badge (the S14c family
    /// look: 22 % of the tile). Y44: the disc sits TOP-RIGHT so it clears the
    /// bottom-right corner control (play badge, subscribe plus). ONE modifier so
    /// every tile/cell reads identically; sizes itself from the decorated view.
    @ViewBuilder
    func offlineUnavailableBadge(_ active: Bool) -> some View {
        if active {
            self.opacity(0.5)
                .overlay {
                    GeometryReader { geo in
                        let badge = CoverBadge.size(tileWidth: geo.size.width)
                        Image(systemName: "wifi.slash")
                            .font(.system(size: badge * 0.5, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: badge, height: badge)
                            .background(.black.opacity(0.4), in: Circle())
                            .padding(4)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                    }
                }
        } else {
            self
        }
    }
}
