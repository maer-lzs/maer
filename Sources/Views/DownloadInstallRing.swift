import SwiftUI

/// App-Store-style install ring shown over a cover while a download runs or is
/// paused. The ring itself is a cancel button with its own bounded hit area, so
/// a tap on the ring cancels the download instead of triggering the card/cell
/// action underneath; taps outside the ring pass through to that parent.
/// Determinate arc for a real fraction, full arc for the indeterminate
/// sentinel (server without a size); a pause glyph replaces the ✕ when paused.
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
                            Circle()
                                .stroke(Color.white.opacity(0.3), lineWidth: lineWidth)
                            Circle()
                                .trim(from: 0, to: fraction < 0 ? 1 : max(0.03, fraction))
                                .stroke(Color.white, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                                .rotationEffect(.degrees(-90))
                            Image(systemName: paused ? "pause.fill" : "xmark")
                                .font(.system(size: d * 0.34, weight: .bold))
                                .foregroundStyle(.white)
                        }
                        // 44pt minimum hit target even on small grid covers.
                        .frame(width: max(44, d), height: max(44, d))
                        .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text("Cancel Download"))
                }
                .frame(width: geo.size.width, height: geo.size.height)
                .animation(.linear(duration: 0.3), value: fraction)
            }
        }
    }
}
