import SwiftUI

/// Download indicator shown over a cover while a download runs or is paused.
/// The ring itself is a cancel button with its own bounded hit area, so a tap on
/// the ring cancels the download instead of triggering the card/cell action
/// underneath; taps outside the ring pass through to that parent.
///
/// S11: the ring/spinner is the shared `UnifiedDownloadRing` — a determinate
/// ring for a known size, an indeterminate spinner for the `-1` sentinel
/// (server without a size), identical to the podcast/music controls. Over the
/// cover it keeps the dim backdrop and a ✕ / pause affordance in the middle.
/// Renders nothing when the item is not downloading.
struct DownloadInstallRing: View {
    let itemId: String
    /// Ring diameter relative to the smaller container edge.
    var diameterFraction: CGFloat = 0.4
    var lineWidth: CGFloat = 3

    @ObservedObject private var downloads = DownloadManager.shared

    var body: some View {
        if let phase = downloads.phase[itemId], let fraction = phase.progress {
            GeometryReader { geo in
                let d = min(geo.size.width, geo.size.height) * diameterFraction
                let paused: Bool = { if case .paused = phase { return true } else { return false } }()
                ZStack {
                    Color.black.opacity(0.45)
                    Button {
                        downloads.cancelDownload(itemId: itemId)
                    } label: {
                        ZStack {
                            UnifiedDownloadRing(fraction: fraction, lineWidth: lineWidth, tint: .white)
                                .frame(width: d, height: d)
                            // Cancel/pause glyph in the middle. The indeterminate
                            // spinner is its own affordance (tap still cancels),
                            // so no ✕ is layered on top of it.
                            if paused {
                                glyph("pause.fill", d: d)
                            } else if fraction >= 0 {
                                glyph("xmark", d: d)
                            }
                        }
                        // 44pt minimum hit target even on small grid covers.
                        .frame(width: max(44, d), height: max(44, d))
                        .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text("Cancel Download"))
                }
                .frame(width: geo.size.width, height: geo.size.height)
            }
        }
    }

    private func glyph(_ name: String, d: CGFloat) -> some View {
        Image(systemName: name)
            .font(.system(size: d * 0.34, weight: .bold))
            .foregroundStyle(.white)
    }
}
