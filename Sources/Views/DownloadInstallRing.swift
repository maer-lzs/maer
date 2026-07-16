import SwiftUI

/// Download indicator shown over a cover while a download runs or is paused.
/// It is a cancel button with its own bounded hit area, so a tap cancels the
/// download instead of triggering the card/cell action underneath; taps outside
/// pass through to that parent.
///
/// S11b: DISCREET podcast-spinner look (was a big App-Store ring with a
/// full-cover dim + ✕). A small centered badge — dark disc + the shared
/// `UnifiedDownloadRing` (determinate ring for a known size, indeterminate
/// spinner for the `-1` sentinel) — so the book grid/card read like the podcast
/// and music download controls. A pause glyph replaces nothing extra when
/// paused. Renders nothing when the item is not downloading.
struct DownloadInstallRing: View {
    let itemId: String
    /// S11c: cover/tile width — the badge sizes to it via CoverBadge (22 %,
    /// [18,44]). Default keeps old call sites source-compatible.
    var tileWidth: CGFloat = 180
    var lineWidth: CGFloat = 3

    @ObservedObject private var downloads = DownloadManager.shared

    var body: some View {
        if let phase = downloads.phase[itemId], let fraction = phase.progress {
            let paused: Bool = { if case .paused = phase { return true } else { return false } }()
            let badge = CoverBadge.size(tileWidth: tileWidth)
            let hit = max(44, badge)   // keep a comfortable tap target
            Button {
                downloads.cancelDownload(itemId: itemId)
            } label: {
                ZStack {
                    Circle().fill(.black.opacity(0.4))
                        .frame(width: badge, height: badge)
                    UnifiedDownloadRing(fraction: fraction, lineWidth: 2.5, tint: .white)
                        .frame(width: badge * 0.55, height: badge * 0.55)
                    if paused {
                        Image(systemName: "pause.fill")
                            .font(.system(size: badge * 0.3, weight: .bold))
                            .foregroundStyle(.white)
                    }
                }
                .frame(width: hit, height: hit)
                .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Cancel Download"))
            // S11c: bottom-right of the cover (badge family), with a small inset.
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
            .padding(4)
        }
    }
}
