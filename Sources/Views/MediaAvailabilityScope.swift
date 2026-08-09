// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import SwiftUI

/// TF4/E1: THE single observer of `DownloadManager`/`NetworkMonitor` for a card
/// or tile. It resolves the pure `MediaAvailability.offlineUnavailable` predicate
/// (Y60) for ONE item and hands the `unavailable` value to its content — which
/// stays value-driven (`.offlineUnavailableBadge`, `MediaTile(unavailable:)`).
///
/// Why it exists: `DownloadManager` republishes `phase` on every download
/// progress tick, re-rendering every OBSERVING view. When whole containers
/// (Home page, cards, cells) observed the globals directly, a single tick
/// re-rendered the entire surface — the visible v2.6 hitch, worst with a
/// 186-part book whose chapter list was re-validated per render. Now the
/// containers observe nothing; only this small scope (wrapping just the cover
/// that dims/badges) re-renders on a tick. It is a ONE-POINT system (Regel 2):
/// new cards/tiles inherit it and future availability fixes land in one place.
/// The download badge stays the separate, self-observing `CardDownloadBadge`.
struct MediaAvailabilityScope<Content: View>: View {
    let itemId: String
    /// Cell-cost sweep: cases whose "downloaded" notion is not a single item id
    /// (a show = any episode downloaded; a catalog tile = never) resolve it
    /// here — the scope stays THE one observing leaf either way.
    var isDownloadedOverride: (() -> Bool)? = nil
    @ViewBuilder var content: (_ unavailable: Bool) -> Content
    @ObservedObject private var downloadManager = DownloadManager.shared
    @ObservedObject private var networkMonitor = NetworkMonitor.shared

    var body: some View {
        content(MediaAvailability.offlineUnavailable(
            isConnected: networkMonitor.isConnected,
            isDownloaded: isDownloadedOverride?() ?? downloadManager.isDownloaded(itemId: itemId)))
    }
}
