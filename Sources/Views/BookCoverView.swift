// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import SwiftUI

/// Cover with a thin progress bar below and the stack of marks at the top
/// right: the kind in a mixed row, the availability (download failed,
/// downloaded or not available offline), finished.
///
/// Cell-cost sweep: the view itself carries NO global observers and NO
/// GeometryReader. Every grid cell used to set up two Combine subscriptions
/// and a layout subpass on creation (the per-cell scroll bump). The offline
/// dim resolves in the MediaAvailabilityScope leaf, the live download state
/// in the tiny observing BookAvailabilityMark; the progress bar computes from
/// the KNOWN `size` instead of measuring it.
struct BookCoverView: View {
    let url: URL?
    let progress: BookProgress?
    /// Optional. Only needed so the download indicator knows which book to
    /// check the status for. Without itemId no indicator is shown.
    var itemId: String? = nil
    var size: CGFloat = 56
    /// The kind of this cover in a mixed row (`stackedKind`), nil elsewhere.
    @Environment(\.coverGlyphKind) private var kind
    @ScaledMetric(relativeTo: .title3) private var markDiameter: CGFloat = 22

    /// The marks this cover carries. Availability stands whenever the
    /// book is known; its leaf draws nothing while there is nothing to say.
    private var marks: [CoverGlyph] {
        (kind == nil ? [] : [.kind]) + (itemId == nil ? [] : [.availability])
            + (progress?.countsAsFinished == true ? [.finished] : [])
    }

    var body: some View {
        VStack(spacing: 4) {
            // Offline, a title that is not on the device is not playable.
            // Dim it and mark it instead of filtering it out. Reactive on BOTH
            // sources (reconnect / finishing startup scan) via the scope leaf.
            if let itemId {
                MediaAvailabilityScope(itemId: itemId) { unavailable in
                    cover(unavailable: unavailable)
                }
            } else {
                cover(unavailable: false)
            }

            progressBar
        }
    }

    private func cover(unavailable: Bool) -> some View {
        Group {
            if url == nil {
                placeholder
            } else {
                // Small cells get the cheap thumbnail tier; large
                // presentations (detail cover ≥ ~300 pt) the full image.
                CachedAsyncImage(url: url, useThumbnail: size <= 200) { image, pixels in
                    // Small cells sit in scrolling grids, so they take the
                    // cheap backdrop; a large cover is alone on its surface
                    // and can afford the blurred enlargement.
                    CoverFitting(image: image, pixelSize: pixels,
                                 backdrop: size <= 200 ? .neutral : .blurredSelf)
                } placeholder: {
                    placeholder.overlay(ProgressView().scaleEffect(0.6))
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        // Finished books are visually "ticked off" in addition to the
        // checkmark. Desaturated and slightly dimmed.
        .saturation(progress?.countsAsFinished == true ? 0 : 1)
        .opacity(progress?.countsAsFinished == true ? 0.55 : (unavailable ? 0.5 : 1))
        // The one stack at the top right. Before, the finished check and
        // the offline disc shared this corner and the download state stood
        // at the bottom left. The bottom right keeps room for the install
        // ring the enclosing cell lays over the cover (see BookGridCell), so
        // a tap on the ring cancels instead of navigating.
        .overlay(alignment: .topTrailing) {
            CoverGlyphStack(present: marks, coverSide: size, cornerSide: CoverBadge.size(tileWidth: size) + 10,
                            label: { mark in
                                switch mark {
                                case .kind: Text(verbatim: kind?.label ?? "")
                                case .finished: Text("Finished")
                                default: unavailable ? Text("Not available offline") : Text(verbatim: "")
                                }
                            }) { mark in
                switch mark {
                case .kind: if let kind { KindGlyph(kind: kind) }
                case .availability: if let itemId { BookAvailabilityMark(itemId: itemId, unavailable: unavailable) }
                default: finishedMark
                }
            }
        }
    }

    /// Finished: a white check on the disc of the tone.
    private var finishedMark: some View {
        Image(systemName: "checkmark")
            .font(.system(size: markDiameter * 0.45, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: markDiameter, height: markDiameter)
            .glyphDisc()
            .padding(5)
            .accessibilityLabel(Text("Finished"))
    }

    /// Thin bar below the cover. Width from the KNOWN cover size, no
    /// GeometryReader (the bar spans exactly `size`).
    @ViewBuilder
    private var progressBar: some View {
        if let progress, progress.isStarted {
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.secondary.opacity(0.25))
                Capsule()
                    .fill(AppTheme.accent)
                    .frame(width: max(3, size * progress.fraction))
            }
            .frame(width: size, height: 3)
        } else {
            Color.clear.frame(width: size, height: 3)
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

/// The availability mark of a book cover in the stack: download failed,
/// else downloaded, else not available offline, else nothing. The ONE
/// observing leaf of the book cell (its purpose IS the live download
/// state; it is tiny).
struct BookAvailabilityMark: View {
    let itemId: String
    let unavailable: Bool
    private let downloadManager = DownloadManager.shared
    @ObservedObject private var downloadStock = DownloadManager.stock
    @ObservedObject private var downloadProgress: ItemDownloadProgress
    @ScaledMetric(relativeTo: .title3) private var diameter: CGFloat = 22

    init(itemId: String, unavailable: Bool) {
        self.itemId = itemId
        self.unavailable = unavailable
        _downloadProgress = ObservedObject(wrappedValue: DownloadManager.progress.item(itemId))
    }

    var body: some View {
        if case .failed = downloadManager.phase[itemId] {
            // A failure keeps its signal colour, like a refused feed.
            Image(systemName: "exclamationmark")
                .font(.system(size: diameter * 0.45, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: diameter, height: diameter)
                .background(Circle().fill(AppTheme.accent))
                .padding(5)
                .accessibilityLabel(Text("Download failed"))
        } else if downloadManager.isDownloaded(itemId: itemId) {
            DownloadedMark(size: .large)
                .padding(4)
        } else if unavailable {
            OfflineUnavailableBadge().padding(5)
        }
    }
}
