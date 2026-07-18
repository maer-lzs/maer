import SwiftUI

/// The Home tab's standard grid tile (Teil 1, rebuilt from the former
/// EpisodeTile): a square image with slots —
/// - optional small corner badge at the image's bottom-LEFT (~24 pt, white
///   border; the featured cards' show-badge pattern),
/// - a corner control at the image's bottom-RIGHT (usually `MediaTilePlayBadge`
///   for direct play; Discover passes its subscribe control),
/// - a thin progress bar along the image's bottom edge for started items,
/// - a 2-line title and an OPTIONAL subtitle below.
/// The tap target is the caller's (`onTap`); the corner control is a sibling
/// overlay so its taps never trigger the tile navigation underneath.
struct MediaTile<Corner: View>: View {
    let title: String
    var subtitle: String? = nil
    let coverURL: URL?
    var placeholderSystemImage: String = "mic"
    /// Image crop behaviour inside the square: `.fill` crops, `.fit` letterboxes.
    var imageContentMode: ContentMode = .fill
    /// Small badge at the image's bottom-left (e.g. the show cover on an
    /// episode tile) — hidden when nil.
    var cornerBadgeURL: URL? = nil
    /// 0…1 → thin progress bar at the image's bottom edge; nil/0 hides it.
    var progress: Double? = nil
    let onTap: () -> Void
    @ViewBuilder let corner: () -> Corner

    private static var imageShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button(action: onTap) { image }
                .buttonStyle(.plain)
                // Sibling overlay: corner-control taps must not also fire onTap.
                .overlay(alignment: .bottomTrailing) { corner().padding(5) }
                .overlay(alignment: .bottomLeading) { cornerBadge }

            Button(action: onTap) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.caption.weight(.medium))
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, minHeight: 32, alignment: .topLeading)
                    if let subtitle {
                        Text(subtitle)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .buttonStyle(.plain)
        }
    }

    private var image: some View {
        CachedAsyncImage(url: coverURL, useThumbnail: true) { image in
            image.resizable().aspectRatio(1, contentMode: imageContentMode)
        } placeholder: {
            Self.imageShape
                .fill(.quaternary)
                .overlay(Image(systemName: placeholderSystemImage).foregroundStyle(.secondary))
        }
        .aspectRatio(1, contentMode: .fit)
        .frame(maxWidth: .infinity)
        .overlay(alignment: .bottom) { progressBar }
        .clipShape(Self.imageShape)
    }

    /// Thin bar along the image's bottom edge — only for started items.
    @ViewBuilder
    private var progressBar: some View {
        if let progress, progress > 0 {
            GeometryReader { geo in
                Rectangle().fill(.white.opacity(0.35))
                Rectangle()
                    .fill(AppTheme.accent)
                    .frame(width: geo.size.width * min(max(progress, 0), 1))
            }
            .frame(height: 3)
        }
    }

    /// The featured cards' show-badge pattern at tile scale: ~24 pt, rounded,
    /// white border.
    @ViewBuilder
    private var cornerBadge: some View {
        if let cornerBadgeURL {
            CachedAsyncImage(url: cornerBadgeURL, useThumbnail: true) { image in
                image.resizable().aspectRatio(contentMode: .fill)
            } placeholder: { Color.clear }
            .frame(width: 24, height: 24)
            .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous)
                .stroke(.white.opacity(0.6), lineWidth: 1))
            .padding(5)
        }
    }
}

extension MediaTile where Corner == EmptyView {
    init(title: String, subtitle: String? = nil, coverURL: URL?,
         placeholderSystemImage: String = "mic", imageContentMode: ContentMode = .fill,
         cornerBadgeURL: URL? = nil, progress: Double? = nil, onTap: @escaping () -> Void) {
        self.init(title: title, subtitle: subtitle, coverURL: coverURL,
                  placeholderSystemImage: placeholderSystemImage,
                  imageContentMode: imageContentMode, cornerBadgeURL: cornerBadgeURL,
                  progress: progress, onTap: onTap) { EmptyView() }
    }
}

/// Standard bottom-right corner control: the small play badge (direct start).
struct MediaTilePlayBadge: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "play.circle.fill")
                .font(.title3)
                .symbolRenderingMode(.palette)
                .foregroundStyle(.white, .black.opacity(0.45))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("Play"))
    }
}
