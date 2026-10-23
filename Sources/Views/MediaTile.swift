// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import SwiftUI

/// The Home tab's standard grid tile (Teil 1, rebuilt from the former
/// EpisodeTile): a square image with slots.
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
    /// episode tile). Hidden when nil.
    var cornerBadgeURL: URL? = nil
    /// The lock is anchored BY THE COMPONENT. On the cover, at the family
    /// position, never at the text. Call sites hand the answer of
    /// `PodcastSubscriptions.lock(feedURL:)`, or `.none` for what is no
    /// feed; there is no default, so no feed tile forgets its lock.
    let lock: FeedLock
    /// 0…1 → thin progress bar at the image's bottom edge; nil/0 hides it.
    var progress: Double? = nil
    /// Third text line (the library card's time line). Laid out
    /// only when the CALLER opts in, so rows without it keep their height.
    /// Pass an empty string to reserve the line without content.
    var meta: String? = nil
    /// Card families that want the single-line title (the free
    /// catalog rows) pass 1; the slot stays RESERVED either way, so cells
    /// remain equally tall.
    var titleLineLimit: Int = 2
    /// Short text capsule at the cover's BOTTOM-LEFT. The licence
    /// class of a catalog item. Deliberately text, not a glyph: SF Symbols
    /// carries no trademarks, and three invented signs would mean nothing.
    /// Sits opposite the corner control (bottom-right), so the two never
    /// stack, and rides ON the cover so the reserved text lines below stay
    /// untouched (jank rule).
    var badgeText: String? = nil
    /// Optional SF symbol INSIDE the capsule, before the word. The origin
    /// capsule is a generic video symbol plus the platform name, the word
    /// carries it and the symbol is Beiwerk with a fallback ladder. No
    /// trademark glyphs, same rule as badgeText.
    var badgeSystemImage: String? = nil
    /// Unavailable content (offline, not downloaded) dims AND carries the
    /// white wifi.slash badge. Dimming alone never carries the state.
    var unavailable: Bool = false
    /// A caller-supplied square cover replacing the `coverURL` image
    /// (playlist cards pass `PlaylistArtwork`, the 2×2 mosaic). The
    /// coverOverride pattern for the poster tile. Progress/badges/clip stay.
    /// Cell-cost sweep: CONCRETE generic instead of `AnyView`. Type erasure
    /// taxed every tile creation/diff (Lazy containers rebuild cells on entry).
    let coverOverride: CoverOverride?
    let onTap: () -> Void
    @ViewBuilder let corner: () -> Corner

    init(title: String, subtitle: String? = nil, coverURL: URL?,
         placeholderSystemImage: String = "mic", imageContentMode: ContentMode = .fill,
         cornerBadgeURL: URL? = nil, lock: FeedLock,
         progress: Double? = nil, unavailable: Bool = false,
         meta: String? = nil, titleLineLimit: Int = 2, badgeText: String? = nil,
         badgeSystemImage: String? = nil,
         coverOverride: CoverOverride?,
         onTap: @escaping () -> Void, @ViewBuilder corner: @escaping () -> Corner) {
        self.title = title
        self.subtitle = subtitle
        self.coverURL = coverURL
        self.placeholderSystemImage = placeholderSystemImage
        self.imageContentMode = imageContentMode
        self.cornerBadgeURL = cornerBadgeURL
        self.lock = lock
        self.progress = progress
        self.unavailable = unavailable
        self.meta = meta
        self.titleLineLimit = titleLineLimit
        self.badgeText = badgeText
        self.badgeSystemImage = badgeSystemImage
        self.coverOverride = coverOverride
        self.onTap = onTap
        self.corner = corner
    }

    /// The side of the cover, measured; decides how many marks fit.
    @State private var coverSide: CGFloat?
    /// The height the corner control takes with its inset, grown with the
    /// text like the play glyph.
    @ScaledMetric(relativeTo: .title3) private var cornerSide: CGFloat = 32

    /// The kind of this tile in a mixed row (`stackedKind`), nil elsewhere.
    @Environment(\.coverGlyphKind) private var kind

    private static var imageShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button(action: onTap) { image }
                .buttonStyle(.plain)
                // The kind, the lock and the offline disc stand in the one
                // stack at the top right, in this order, so no mark lies over
                // another. The bottom right carries the tile's control.
                .overlay(alignment: .topTrailing) {
                    StandardCoverMarks(kind: kind, lock: lock, availability: unavailable ? .offline : nil,
                                       coverSide: coverSide, cornerSide: cornerSide)
                }
                // Sibling overlay: corner-control taps must not also fire onTap.
                .overlay(alignment: .bottomTrailing) { corner().padding(5) }
                // Two places at the bottom-left, never one over the other:
                // the show badge first, the capsule beside it.
                .overlay(alignment: .bottomLeading) {
                    HStack(alignment: .bottom, spacing: 0) {
                        cornerBadge
                        licenceCapsule
                    }
                }

            Button(action: onTap) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.caption.weight(.medium))
                        // Layout-shift: reserve BOTH lines at every type size.
                        // The old fixed minHeight matched two lines only at the
                        // default size, so grid rows went uneven at larger
                        // Dynamic Type (variable LazyVGrid row heights jump
                        // while scrolling, Apple Forums 685461).
                        .lineLimit(titleLineLimit, reservesSpace: true)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                    // Jank convention: the subtitle slot is always laid out
                    // (invisible placeholder when nil) so tiles with and
                    // without a subtitle are equally tall.
                    Text(subtitle ?? " ")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1, reservesSpace: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    // The library card's time line, same rule.
                    // Always laid out where the row asks for it, so a title
                    // without runtime never shrinks its cell.
                    if let meta {
                        Text(meta.isEmpty ? " " : meta)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1, reservesSpace: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .buttonStyle(.plain)
        }
    }

    @ViewBuilder
    private var licenceCapsule: some View {
        if let badgeText, !badgeText.isEmpty {
            CoverCapsule(text: badgeText, systemImage: badgeSystemImage)
        }
    }

    @ViewBuilder
    private var image: some View {
        Group {
            if let coverOverride {
                coverOverride
            } else {
                CachedAsyncImage(url: coverURL, useThumbnail: true) { image, pixels in
                    // A surface that explicitly asked to FIT keeps
                    // fitting; the shape rule only replaces the fill,
                    // which is the mode that crops. Tiles live in
                    // scrolling grids, so the backdrop stays cheap.
                    if imageContentMode == .fill {
                        CoverFitting(image: image, pixelSize: pixels, backdrop: .neutral)
                    } else {
                        image.resizable().aspectRatio(1, contentMode: imageContentMode)
                    }
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
        // The corner control and the marks stay crisp ON TOP (sibling
        // overlays in body); only the image dims.
        .opacity(unavailable ? 0.5 : 1)
        // The shorter side: a cover pressed out of square must not promise
        // room its height does not have.
        .onGeometryChange(for: CGFloat.self) { min($0.size.width, $0.size.height) } action: { coverSide = $0 }
    }

    /// Thin bar along the image's bottom edge. Only for started items.
    /// Cell-cost sweep: NO GeometryReader (a layout subpass per tile). The
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
         cornerBadgeURL: URL? = nil, lock: FeedLock,
         progress: Double? = nil, unavailable: Bool = false,
         meta: String? = nil, titleLineLimit: Int = 2, badgeText: String? = nil,
         badgeSystemImage: String? = nil,
         onTap: @escaping () -> Void, @ViewBuilder corner: @escaping () -> Corner) {
        self.init(title: title, subtitle: subtitle, coverURL: coverURL,
                  placeholderSystemImage: placeholderSystemImage,
                  imageContentMode: imageContentMode, cornerBadgeURL: cornerBadgeURL,
                  lock: lock,
                  progress: progress, unavailable: unavailable,
                  meta: meta, titleLineLimit: titleLineLimit, badgeText: badgeText,
                  badgeSystemImage: badgeSystemImage, coverOverride: nil,
                  onTap: onTap, corner: corner)
    }
}

extension MediaTile where Corner == EmptyView {
    /// Cover-override tiles without a corner (the playlist poster card).
    init(title: String, subtitle: String? = nil, coverURL: URL?,
         placeholderSystemImage: String = "mic", imageContentMode: ContentMode = .fill,
         cornerBadgeURL: URL? = nil, lock: FeedLock, progress: Double? = nil, unavailable: Bool = false,
         meta: String? = nil, titleLineLimit: Int = 2, badgeText: String? = nil,
         coverOverride: CoverOverride,
         onTap: @escaping () -> Void) {
        self.init(title: title, subtitle: subtitle, coverURL: coverURL,
                  placeholderSystemImage: placeholderSystemImage,
                  imageContentMode: imageContentMode, cornerBadgeURL: cornerBadgeURL,
                  lock: lock, progress: progress, unavailable: unavailable,
                  meta: meta, titleLineLimit: titleLineLimit, badgeText: badgeText, coverOverride: coverOverride,
                  onTap: onTap, corner: { EmptyView() })
    }
}

extension MediaTile where Corner == EmptyView, CoverOverride == EmptyView {
    /// Plain tiles (no corner, no override).
    init(title: String, subtitle: String? = nil, coverURL: URL?,
         placeholderSystemImage: String = "mic", imageContentMode: ContentMode = .fill,
         cornerBadgeURL: URL? = nil, lock: FeedLock, progress: Double? = nil, unavailable: Bool = false,
         meta: String? = nil, titleLineLimit: Int = 2, badgeText: String? = nil,
         onTap: @escaping () -> Void) {
        self.init(title: title, subtitle: subtitle, coverURL: coverURL,
                  placeholderSystemImage: placeholderSystemImage,
                  imageContentMode: imageContentMode, cornerBadgeURL: cornerBadgeURL,
                  lock: lock, progress: progress, unavailable: unavailable,
                  meta: meta, titleLineLimit: titleLineLimit, badgeText: badgeText, coverOverride: nil,
                  onTap: onTap, corner: { EmptyView() })
    }
}

/// Standard bottom-right corner control: the small play badge (direct start),
/// a white play on the disc of the tone, as large as the offline disc.
struct MediaTilePlayBadge: View {
    let action: () -> Void
    @ScaledMetric(relativeTo: .title3) private var diameter: CGFloat = 22

    var body: some View {
        Button(action: action) {
            Image(systemName: "play.fill")
                .font(.system(size: diameter * 0.45, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: diameter, height: diameter)
                .glyphDisc()
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("Play"))
    }
}
