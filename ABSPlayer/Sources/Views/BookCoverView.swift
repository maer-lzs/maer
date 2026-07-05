import SwiftUI

/// Cover mit dünnem Fortschrittsbalken darunter (bzw. Häkchen wenn beendet).
struct BookCoverView: View {
    let url: URL?
    let progress: BookProgress?
    var size: CGFloat = 56

    var body: some View {
        VStack(spacing: 4) {
            ZStack(alignment: .topTrailing) {
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

                if progress?.isFinished == true {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: size * 0.28))
                        .foregroundStyle(.white, .green)
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
