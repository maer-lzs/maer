// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later

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
    @ObservedObject private var networkMonitor = NetworkMonitor.shared

    /// B2: offline, a title that is not on the device is not playable — dim it
    /// and mark it, instead of filtering it out of the library. Reactive on
    /// BOTH sources: reconnecting or the finishing startup scan un-dims live.
    private var isOfflineUnavailable: Bool {
        guard let itemId, !networkMonitor.isConnected else { return false }
        return !downloadManager.isDownloaded(itemId: itemId)
    }

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
            .opacity(progress?.isFinished == true ? 0.55 : (isOfflineUnavailable ? 0.5 : 1))
            // Y44: TOP-RIGHT holds either the finished check or — for an
            // unfinished, offline, not-downloaded title — the wifi.slash disc
            // (same family look as the shared modifier). They're mutually
            // exclusive (a finished title needs no "can't play offline" hint),
            // so the corner never doubles up.
            .overlay(alignment: .topTrailing) {
                if progress?.isFinished == true {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: size * 0.14))
                        .foregroundStyle(.white, AppTheme.accent)
                        .padding(4)
                } else if isOfflineUnavailable {
                    OfflineUnavailableBadge().padding(5)
                }
            }
            // Install ring is layered by the enclosing cell as a SIBLING of the
            // NavigationLink (see BookGridCell), so a tap on the ring cancels
            // instead of navigating — a ring nested in the link label here
            // could not win the hit.
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
