// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

/// Shared layout for a media list row — used by podcast episode rows and the
/// downloaded-audiobook rows so both surfaces read identically (Regel 2):
/// a 64pt cover with optional offline/downloaded badges, and a text column
/// (eyebrow · title · optional progress bar · meta line). The trailing control
/// cluster stays at each call site (its actions differ per medium).
struct MediaRowContent<CoverOverride: View>: View {
    let coverURL: URL?
    /// Uppercased eyebrow line above the title (show name / author).
    var eyebrow: String? = nil
    let title: String
    var titleDimmed = false
    var coverDimmed = false
    var offlineBadge = false
    var downloadedBadge = false
    /// In-progress bar (0…1) below the title; nil hides it.
    var progressFraction: Double? = nil
    var meta: String? = nil
    var showsPlayedCheck = false
    /// Placeholder glyph when there is no cover (mic for podcasts, book for books).
    var placeholderSystemImage = "mic"
    /// V7: cover edge length. Default 64; the Up-Next queue rows pass a larger
    /// value to set themselves apart from the compact Downloaded list.
    var coverSize: CGFloat = 64
    /// Y58: a caller-supplied cover view replacing the `coverURL` image (radio
    /// rows pass `RadioArtwork`, so a missing favicon reads the same as in the
    /// player). Framing, clipping, dimming and badges stay MediaRowContent's.
    /// Cell-cost sweep: CONCRETE generic instead of `AnyView` (type erasure
    /// taxed every row creation/diff in the Lazy containers).
    var coverOverride: CoverOverride?
    /// Pinchflat Paket B: origin capsule in the meta line (compact form —
    /// height-neutral, so the reserved cell height stays data-independent).
    var showsOriginCapsule = false

    init(coverURL: URL?, eyebrow: String? = nil, title: String,
         titleDimmed: Bool = false, coverDimmed: Bool = false,
         offlineBadge: Bool = false, downloadedBadge: Bool = false,
         progressFraction: Double? = nil, meta: String? = nil,
         showsPlayedCheck: Bool = false, placeholderSystemImage: String = "mic",
         coverSize: CGFloat = 64, showsOriginCapsule: Bool = false,
         coverOverride: CoverOverride?) {
        self.coverURL = coverURL
        self.eyebrow = eyebrow
        self.title = title
        self.titleDimmed = titleDimmed
        self.coverDimmed = coverDimmed
        self.offlineBadge = offlineBadge
        self.downloadedBadge = downloadedBadge
        self.progressFraction = progressFraction
        self.meta = meta
        self.showsPlayedCheck = showsPlayedCheck
        self.placeholderSystemImage = placeholderSystemImage
        self.coverSize = coverSize
        self.coverOverride = coverOverride
        self.showsOriginCapsule = showsOriginCapsule
    }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            artwork
            VStack(alignment: .leading, spacing: 3) {
                // Jank convention (docs/components.md): cells in lazy
                // containers have a DATA-INDEPENDENT height. Every slot is
                // always laid out and reserves its space — a nil value renders
                // an invisible placeholder, so the realized height never
                // depends on this row's data (a late height correction is the
                // weak scroll bump, Apple Forums 685461).
                Text((eyebrow ?? " ").uppercased())
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1, reservesSpace: true)
                Text(title)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(titleDimmed ? .secondary : .primary)
                    .lineLimit(2, reservesSpace: true)
                ProgressView(value: progressFraction ?? 0)
                    .tint(AppTheme.accent)
                    .padding(.top, 2)
                    .opacity(progressFraction != nil ? 1 : 0)
                HStack(spacing: 6) {
                    if showsPlayedCheck {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    if showsOriginCapsule { OriginCapsule(compact: true) }
                    Text(meta ?? " ")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1, reservesSpace: true)
                }
                .padding(.top, 1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }

    private var artwork: some View {
        let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
        return Group {
            if let coverOverride {
                coverOverride
            } else if let coverURL {
                CachedAsyncImage(url: coverURL, useThumbnail: true) { image in
                    image.resizable().aspectRatio(contentMode: .fill)
                } placeholder: {
                    shape.fill(Color.secondary.opacity(0.15))
                }
            } else {
                shape.fill(Color.secondary.opacity(0.15))
                    .overlay(Image(systemName: placeholderSystemImage).font(.title3).foregroundStyle(.secondary))
            }
        }
        .frame(width: coverSize, height: coverSize)
        .clipShape(shape)
        .opacity(coverDimmed ? 0.5 : 1)
        .overlay(alignment: .topTrailing) {
            if offlineBadge {
                Image(systemName: "wifi.slash")
                    .font(.caption2)
                    .foregroundStyle(.white)   // S14b: full symbol white
                    .padding(3)
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if downloadedBadge {
                Image(systemName: "checkmark.circle.fill")
                    .font(.caption)
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, .green)
                    .padding(2)
            }
        }
    }
}


extension MediaRowContent where CoverOverride == EmptyView {
    /// The standard row (no cover override) — every non-radio caller.
    init(coverURL: URL?, eyebrow: String? = nil, title: String,
         titleDimmed: Bool = false, coverDimmed: Bool = false,
         offlineBadge: Bool = false, downloadedBadge: Bool = false,
         progressFraction: Double? = nil, meta: String? = nil,
         showsPlayedCheck: Bool = false, placeholderSystemImage: String = "mic",
         coverSize: CGFloat = 64, showsOriginCapsule: Bool = false) {
        self.init(coverURL: coverURL, eyebrow: eyebrow, title: title,
                  titleDimmed: titleDimmed, coverDimmed: coverDimmed,
                  offlineBadge: offlineBadge, downloadedBadge: downloadedBadge,
                  progressFraction: progressFraction, meta: meta,
                  showsPlayedCheck: showsPlayedCheck,
                  placeholderSystemImage: placeholderSystemImage,
                  coverSize: coverSize, showsOriginCapsule: showsOriginCapsule,
                  coverOverride: nil)
    }
}
