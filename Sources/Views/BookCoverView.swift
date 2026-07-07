import SwiftUI

/// Cover mit dünnem Fortschrittsbalken darunter, Häkchen bei Fertig-Status
/// oben rechts und Download-Indikator unten links.
struct BookCoverView: View {
    let url: URL?
    let progress: BookProgress?
    /// Optional — nur nötig, damit der Download-Indikator weiß, für welches
    /// Buch er den Status prüfen soll. Ohne itemId wird kein Indikator gezeigt.
    var itemId: String? = nil
    var size: CGFloat = 56

    @ObservedObject private var downloadManager = DownloadManager.shared

    var body: some View {
        VStack(spacing: 4) {
            Group {
                if url == nil {
                    placeholder
                } else {
                    CachedAsyncImage(url: url) { image in
                        image.resizable().aspectRatio(contentMode: .fill)
                    } placeholder: {
                        placeholder.overlay(ProgressView().scaleEffect(0.6))
                    }
                }
            }
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            // Fertig gehörte Bücher werden zusätzlich zum Häkchen optisch
            // "abgehakt" — entsättigt und leicht abgedunkelt.
            .saturation(progress?.isFinished == true ? 0 : 1)
            .opacity(progress?.isFinished == true ? 0.55 : 1)
            .overlay(alignment: .topTrailing) {
                if progress?.isFinished == true {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: size * 0.2))
                        .foregroundStyle(.white, AppTheme.accent)
                        .padding(3)
                }
            }
            .overlay(alignment: .bottomLeading) {
                if let itemId, let fraction = downloadManager.downloadProgress[itemId] {
                    // Laufender Download: Mini-Fortschrittsring.
                    ZStack {
                        Circle()
                            .stroke(Color.white.opacity(0.35), lineWidth: 2)
                        Circle()
                            .trim(from: 0, to: max(0.02, fraction))
                            .stroke(AppTheme.accent, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                    }
                    .frame(width: size * 0.2, height: size * 0.2)
                    .padding(3)
                } else if let itemId, downloadManager.isDownloaded(itemId: itemId) {
                    Image(systemName: "arrow.down.circle.fill")
                        .font(.system(size: size * 0.2))
                        .foregroundStyle(.white, .secondary)
                        .padding(3)
                }
            }

            // Dünner Balken unter dem Cover.
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
