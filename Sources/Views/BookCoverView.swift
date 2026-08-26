// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import SwiftUI

/// Cover with a thin progress bar below, a checkmark for finished status at the
/// top right and a download indicator at the bottom left.
///
/// Cell-cost sweep: the view itself carries NO global observers and NO
/// GeometryReader — every grid cell used to set up two Combine subscriptions
/// and a layout subpass on creation (the per-cell scroll bump). The offline
/// dim resolves in the MediaAvailabilityScope leaf, the live download corner
/// in the tiny observing BookCoverDownloadIcon; the progress bar computes from
/// the KNOWN `size` instead of measuring it.
struct BookCoverView: View {
    let url: URL?
    let progress: BookProgress?
    /// Optional — only needed so the download indicator knows which book to
    /// check the status for. Without itemId no indicator is shown.
    var itemId: String? = nil
    var size: CGFloat = 56

    var body: some View {
        VStack(spacing: 4) {
            // Offline, a title that is not on the device is not playable —
            // dim it and mark it instead of filtering it out. Reactive on BOTH
            // sources (reconnect / finishing startup scan) via the scope leaf.
            if let itemId {
                MediaAvailabilityScope(itemId: itemId) { unavailable in
                    cover(unavailable: unavailable)
                        // Install ring is layered by the enclosing cell as a
                        // SIBLING of the NavigationLink (see BookGridCell), so
                        // a tap on the ring cancels instead of navigating.
                        .overlay(alignment: .bottomLeading) {
                            BookCoverDownloadIcon(itemId: itemId, size: size)
                        }
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
        .saturation(progress?.countsAsFinished == true ? 0 : 1)
        .opacity(progress?.countsAsFinished == true ? 0.55 : (unavailable ? 0.5 : 1))
        // TOP-RIGHT holds either the finished check or — for an
        // unfinished, offline, not-downloaded title — the wifi.slash disc
        // (same family look as the shared modifier). They're mutually
        // exclusive (a finished title needs no "can't play offline" hint),
        // so the corner never doubles up.
        .overlay(alignment: .topTrailing) {
            if progress?.countsAsFinished == true {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: size * 0.14))
                    .foregroundStyle(.white, AppTheme.accent)
                    .padding(4)
            } else if unavailable {
                OfflineUnavailableBadge().padding(5)
            }
        }
    }

    /// Thin bar below the cover — width from the KNOWN cover size, no
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

/// The cover's bottom-left download corner — the ONE observing leaf of the
/// book cell (its purpose IS the live download state; it is tiny).
struct BookCoverDownloadIcon: View {
    let itemId: String
    let size: CGFloat
    @ObservedObject private var downloadManager = DownloadManager.shared

    var body: some View {
        if case .failed = downloadManager.phase[itemId] {
            Image(systemName: "exclamationmark.circle.fill")
                .font(.system(size: size * 0.14))
                .foregroundStyle(.white, AppTheme.accent)
                .padding(4)
        } else if downloadManager.isDownloaded(itemId: itemId) {
            Image(systemName: "arrow.down.circle.fill")
                .font(.system(size: size * 0.14))
                .foregroundStyle(.white, .secondary)
                .padding(4)
        }
    }
}
