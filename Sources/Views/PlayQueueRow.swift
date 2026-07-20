// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

/// One row of the GLOBAL Up-Next queue. Renders any media type — audiobook,
/// podcast episode, music album/song — uniformly through the shared
/// `MediaRowContent` (Regel 2: one parametrised component, used by both the
/// Up-Next section and the reorderable queue page). Tapping plays the item,
/// which removes it from the queue via the coordinator ("start = flies out").
struct PlayQueueRow: View {
    let item: LibraryItem
    @ObservedObject var playerCoordinator: PlayerCoordinator
    // Y60: an offline, not-downloaded queue entry must dim AND carry the white
    // wifi.slash glyph (the A3 rule), like every other MediaRowContent surface.
    @ObservedObject private var networkMonitor = NetworkMonitor.shared
    @ObservedObject private var downloadManager = DownloadManager.shared

    private var isOfflineUnavailable: Bool {
        MediaAvailability.offlineUnavailable(isConnected: networkMonitor.isConnected,
                                             isDownloaded: downloadManager.isDownloaded(itemId: item.id))
    }

    var body: some View {
        Button {
            Task { await playerCoordinator.open(item: item) }
        } label: {
            MediaRowContent(
                coverURL: AppSession.shared.coverURL(forItemId: item.id),
                eyebrow: item.media?.metadata?.authorName ?? item.author,
                title: item.title,
                titleDimmed: isOfflineUnavailable,
                coverDimmed: isOfflineUnavailable,
                offlineBadge: isOfflineUnavailable,
                placeholderSystemImage: placeholderSystemImage
            )
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
    }

    /// Cover-less placeholder glyph by media type.
    private var placeholderSystemImage: String {
        if item.id.hasPrefix("rss:") || item.id.hasPrefix("abspod:") { return "mic" }
        if item.id.hasPrefix("sub:") { return "music.note" }
        return "book.closed"
    }
}
