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
/// in the tiny observing BookCoverMarks; the progress bar computes from
/// the KNOWN `size` instead of measuring it.
struct BookCoverView: View {
    let url: URL?
    let progress: BookProgress?
    /// Optional. Only needed so the download indicator knows which book to
    /// check the status for. Without itemId no indicator is shown.
    var itemId: String? = nil
    var size: CGFloat = 56
    /// The cover alone as a detail page's card (`coverCard()`); the bar
    /// below stays outside it.
    var asCard = false
    /// The kind of this cover in a mixed row (`stackedKind`), nil elsewhere.
    @Environment(\.coverGlyphKind) private var kind

    var body: some View {
        VStack(spacing: CoverProgressBar.gap) {
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
        .coverShape(asCard: asCard)
        // Finished books are visually "ticked off" in addition to the
        // checkmark. Desaturated and slightly dimmed.
        .saturation(progress?.countsAsFinished == true ? 0 : 1)
        .opacity(progress?.countsAsFinished == true ? 0.55 : (unavailable ? 0.5 : 1))
        // The one stack at the top right carries finished, availability and
        // the download state together, so no corner holds two marks over
        // each other. The bottom right keeps room for the install
        // ring the enclosing cell lays over the cover (see BookGridCell), so
        // a tap on the ring cancels instead of navigating.
        .overlay(alignment: .topTrailing) {
            let finished = progress?.countsAsFinished == true
            if let itemId {
                BookCoverMarks(itemId: itemId, unavailable: unavailable, finished: finished, kind: kind, size: size)
            } else {
                StandardCoverMarks(kind: kind, finished: finished, coverSide: size,
                                   cornerSide: CoverBadge.size(tileWidth: size) + 10)
            }
        }
    }

    /// Thin bar below the cover. Width from the KNOWN cover size, no
    /// GeometryReader (the bar spans exactly `size`).
    private var progressBar: some View {
        CoverProgressBar(fraction: progress?.isStarted == true ? progress?.fraction : nil, width: size)
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

/// THE progress bar under a book's cover, in the grids and on the book
/// page alike: a thin track with round ends, `gap` below the cover and as
/// wide as it; nil keeps the room empty, so a row of covers stays level.
struct CoverProgressBar: View {
    var fraction: Double?
    var width: CGFloat

    static let gap: CGFloat = 4
    static let height: CGFloat = 3

    var body: some View {
        if let fraction {
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.secondary.opacity(0.25))
                Capsule()
                    .fill(AppTheme.accent)
                    .frame(width: max(Self.height, width * min(max(fraction, 0), 1)))
            }
            .frame(width: width, height: Self.height)
        } else {
            Color.clear.frame(width: width, height: Self.height)
        }
    }
}

private extension View {
    /// The cover's own shape: the card of a detail page, else the grid's
    /// small rounding.
    @ViewBuilder func coverShape(asCard: Bool) -> some View {
        if asCard {
            coverCard()
        } else {
            clipShape(RoundedRectangle(cornerRadius: 8))
        }
    }
}

/// The marks of a known book: asks the live download state and hands the
/// stack what availability says (`CoverAvailability.of`). The ONE
/// observing leaf of the book cell (its purpose IS the live download
/// state; it is tiny).
struct BookCoverMarks: View {
    let itemId: String
    let unavailable: Bool
    let finished: Bool
    let kind: MediaType?
    let size: CGFloat
    private let downloadManager = DownloadManager.shared
    @ObservedObject private var downloadStock = DownloadManager.stock
    @ObservedObject private var downloadProgress: ItemDownloadProgress

    init(itemId: String, unavailable: Bool, finished: Bool, kind: MediaType?, size: CGFloat) {
        self.itemId = itemId
        self.unavailable = unavailable
        self.finished = finished
        self.kind = kind
        self.size = size
        _downloadProgress = ObservedObject(wrappedValue: DownloadManager.progress.item(itemId))
    }

    var body: some View {
        let failed: Bool = { if case .failed = downloadManager.phase[itemId] { return true }; return false }()
        // The bottom right keeps room for the install ring the enclosing
        // cell lays over the cover.
        StandardCoverMarks(kind: kind,
                           availability: CoverAvailability.of(failed: failed,
                                                              downloaded: downloadManager.isDownloaded(itemId: itemId),
                                                              unavailable: unavailable),
                           finished: finished, coverSide: size, cornerSide: CoverBadge.size(tileWidth: size) + 10)
    }
}
