// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later

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
struct MediaTile<Corner: View, CoverOverride: View>: View {
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
    /// A3: unavailable content (offline, not downloaded) dims AND carries the
    /// white wifi.slash badge — dimming alone never carries the state.
    var unavailable: Bool = false
    /// F5: a caller-supplied square cover replacing the `coverURL` image
    /// (playlist cards pass `PlaylistArtwork`, the 2×2 mosaic) — the Y58
    /// coverOverride pattern for the poster tile. Progress/badges/clip stay.
    /// Cell-cost sweep: CONCRETE generic instead of `AnyView` — type erasure
    /// taxed every tile creation/diff (Lazy containers rebuild cells on entry).
    let coverOverride: CoverOverride?
    let onTap: () -> Void
    @ViewBuilder let corner: () -> Corner

    init(title: String, subtitle: String? = nil, coverURL: URL?,
         placeholderSystemImage: String = "mic", imageContentMode: ContentMode = .fill,
         cornerBadgeURL: URL? = nil, progress: Double? = nil, unavailable: Bool = false,
         coverOverride: CoverOverride?,
         onTap: @escaping () -> Void, @ViewBuilder corner: @escaping () -> Corner) {
        self.title = title
        self.subtitle = subtitle
        self.coverURL = coverURL
        self.placeholderSystemImage = placeholderSystemImage
        self.imageContentMode = imageContentMode
        self.cornerBadgeURL = cornerBadgeURL
        self.progress = progress
        self.unavailable = unavailable
        self.coverOverride = coverOverride
        self.onTap = onTap
        self.corner = corner
    }

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
                        // Layout-shift: reserve BOTH lines at every type size —
                        // the old fixed minHeight matched two lines only at the
                        // default size, so grid rows went uneven at larger
                        // Dynamic Type (variable LazyVGrid row heights jump
                        // while scrolling, Apple Forums 685461).
                        .lineLimit(2, reservesSpace: true)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                    // Jank convention: the subtitle slot is always laid out
                    // (invisible placeholder when nil) so tiles with and
                    // without a subtitle are equally tall.
                    Text(subtitle ?? " ")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1, reservesSpace: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .buttonStyle(.plain)
        }
    }

    @ViewBuilder
    private var image: some View {
        Group {
            if let coverOverride {
                coverOverride
            } else {
                CachedAsyncImage(url: coverURL, useThumbnail: true) { image in
                    image.resizable().aspectRatio(1, contentMode: imageContentMode)
                } placeholder: {
                    Self.imageShape
                        .fill(.quaternary)
                        .overlay(Image(systemName: placeholderSystemImage).foregroundStyle(.secondary))
                }
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .frame(maxWidth: .infinity)
        .overlay(alignment: .bottom) { progressBar }
        .clipShape(Self.imageShape)
        // A3: the corner control stays crisp ON TOP (sibling overlay in body);
        // only the image dims and carries the badge.
        .offlineUnavailableBadge(unavailable)
    }

    /// Thin bar along the image's bottom edge — only for started items.
    /// Cell-cost sweep: NO GeometryReader (a layout subpass per tile) — the
    /// accent fill is a full-width rect scaled by the fraction (pure render
    /// transform, `anchor: .leading`).
    @ViewBuilder
    private var progressBar: some View {
        if let progress, progress > 0 {
            Rectangle().fill(.white.opacity(0.35))
                .overlay(alignment: .leading) {
                    Rectangle()
                        .fill(AppTheme.accent)
                        .scaleEffect(x: min(max(progress, 0), 1), y: 1, anchor: .leading)
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

extension MediaTile where CoverOverride == EmptyView {
    /// Corner-carrying tiles without a cover override (the standard grid tile).
    init(title: String, subtitle: String? = nil, coverURL: URL?,
         placeholderSystemImage: String = "mic", imageContentMode: ContentMode = .fill,
         cornerBadgeURL: URL? = nil, progress: Double? = nil, unavailable: Bool = false,
         onTap: @escaping () -> Void, @ViewBuilder corner: @escaping () -> Corner) {
        self.init(title: title, subtitle: subtitle, coverURL: coverURL,
                  placeholderSystemImage: placeholderSystemImage,
                  imageContentMode: imageContentMode, cornerBadgeURL: cornerBadgeURL,
                  progress: progress, unavailable: unavailable, coverOverride: nil,
                  onTap: onTap, corner: corner)
    }
}

extension MediaTile where Corner == EmptyView {
    /// Cover-override tiles without a corner (the playlist poster card).
    init(title: String, subtitle: String? = nil, coverURL: URL?,
         placeholderSystemImage: String = "mic", imageContentMode: ContentMode = .fill,
         cornerBadgeURL: URL? = nil, progress: Double? = nil, unavailable: Bool = false,
         coverOverride: CoverOverride,
         onTap: @escaping () -> Void) {
        self.init(title: title, subtitle: subtitle, coverURL: coverURL,
                  placeholderSystemImage: placeholderSystemImage,
                  imageContentMode: imageContentMode, cornerBadgeURL: cornerBadgeURL,
                  progress: progress, unavailable: unavailable, coverOverride: coverOverride,
                  onTap: onTap, corner: { EmptyView() })
    }
}

extension MediaTile where Corner == EmptyView, CoverOverride == EmptyView {
    /// Plain tiles (no corner, no override).
    init(title: String, subtitle: String? = nil, coverURL: URL?,
         placeholderSystemImage: String = "mic", imageContentMode: ContentMode = .fill,
         cornerBadgeURL: URL? = nil, progress: Double? = nil, unavailable: Bool = false,
         onTap: @escaping () -> Void) {
        self.init(title: title, subtitle: subtitle, coverURL: coverURL,
                  placeholderSystemImage: placeholderSystemImage,
                  imageContentMode: imageContentMode, cornerBadgeURL: cornerBadgeURL,
                  progress: progress, unavailable: unavailable, coverOverride: nil,
                  onTap: onTap, corner: { EmptyView() })
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
