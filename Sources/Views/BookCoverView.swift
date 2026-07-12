import SwiftUI

/// Cover with a thin progress bar below, a checkmark for finished status at the
/// top right and a download indicator at the bottom left.
struct BookCoverView: View {
    let url: URL?
    let progress: BookProgress?
    /// Optional — only needed so the download indicator knows which book to
    /// check the status for. Without itemId no indicator is shown.
    var itemId: String? = nil
    var size: CGFloat = 56

    @ObservedObject private var downloadManager = DownloadManager.shared

    var body: some View {
        VStack(spacing: 4) {
            Group {
                if url == nil {
                    placeholder
                } else {
                    // Small cells get the cheap thumbnail tier; large
                    // presentations (detail cover ≥ ~300 pt) the full image.
                    CachedAsyncImage(url: url, useThumbnail: size <= 200) { image in
                        image.resizable().aspectRatio(contentMode: .fill)
                    } placeholder: {
                        placeholder.overlay(ProgressView().scaleEffect(0.6))
                    }
                }
            }
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            // Finished books are visually "ticked off" in addition to the
            // checkmark — desaturated and slightly dimmed.
            .saturation(progress?.isFinished == true ? 0 : 1)
            .opacity(progress?.isFinished == true ? 0.55 : 1)
            .overlay(alignment: .topTrailing) {
                if progress?.isFinished == true {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: size * 0.14))
                        .foregroundStyle(.white, AppTheme.accent)
                        .padding(4)
                }
            }
            // App-Store-style install animation: dimmed cover with a
            // centered progress ring while downloading/paused.
            .overlay {
                if let itemId, let phase = downloadManager.phase[itemId],
                   let fraction = phase.progress {
                    ZStack {
                        Color.black.opacity(0.45)
                        Circle()
                            .stroke(Color.white.opacity(0.3), lineWidth: 3)
                            .frame(width: size * 0.4, height: size * 0.4)
                        Circle()
                            .trim(from: 0, to: max(0.03, fraction))
                            .stroke(Color.white, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                            .frame(width: size * 0.4, height: size * 0.4)
                        if case .paused = phase {
                            Image(systemName: "pause.fill")
                                .font(.system(size: size * 0.14, weight: .bold))
                                .foregroundStyle(.white)
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .animation(.linear(duration: 0.3), value: fraction)
                }
            }
            .overlay(alignment: .bottomLeading) {
                if let itemId, case .failed = downloadManager.phase[itemId] {
                    Image(systemName: "exclamationmark.circle.fill")
                        .font(.system(size: size * 0.14))
                        .foregroundStyle(.white, AppTheme.accent)
                        .padding(4)
                } else if let itemId, downloadManager.isDownloaded(itemId: itemId) {
                    Image(systemName: "arrow.down.circle.fill")
                        .font(.system(size: size * 0.14))
                        .foregroundStyle(.white, .secondary)
                        .padding(4)
                }
            }

            // Thin bar below the cover.
            if let progress, progress.isStarted {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(Color.secondary.opacity(0.25))
                        Capsule()
                            .fill(AppTheme.accent)
                            .frame(width: max(3, geo.size.width * progress.fraction))
                    }
                }
                .frame(width: size, height: 3)
            } else {
                Color.clear.frame(width: size, height: 3)
            }
        }
    }

    private var placeholder: some View {
        RoundedRectangle(cornerRadius: 8)
            .fill(Color.secondary.opacity(0.15))
            .overlay(
                Image(systemName: "book.closed")
                    .foregroundStyle(.secondary)
            )
    }
}
