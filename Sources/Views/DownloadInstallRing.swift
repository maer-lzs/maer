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
    /// Kept for source-compatibility with the existing call sites; the badge is
    /// now a fixed discreet size, so the cover-relative diameter is unused.
    var diameterFraction: CGFloat = 0.4
    var lineWidth: CGFloat = 3

    @ObservedObject private var downloads = DownloadManager.shared

    var body: some View {
        if let phase = downloads.phase[itemId], let fraction = phase.progress {
            let paused: Bool = { if case .paused = phase { return true } else { return false } }()
            Button {
                downloads.cancelDownload(itemId: itemId)
            } label: {
                ZStack {
                    Circle().fill(.black.opacity(0.4))
                        .frame(width: 40, height: 40)
                    UnifiedDownloadRing(fraction: fraction, lineWidth: 2.5, tint: .white)
                        .frame(width: 22, height: 22)
                    if paused {
                        Image(systemName: "pause.fill")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(.white)
                    }
                }
                .frame(width: 44, height: 44)   // 44pt hit target
                .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Cancel Download"))
            // Center the discreet badge over the cover area handed to us.
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
