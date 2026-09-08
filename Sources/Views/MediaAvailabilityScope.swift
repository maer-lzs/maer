// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import SwiftUI

/// THE single observer of `DownloadManager` for a card or tile. It resolves
/// the pure `MediaAvailability.offlineUnavailable` predicate for ONE item and
/// hands the `unavailable` value to its content. Which stays value-driven
/// (`.offlineUnavailableBadge`, `MediaTile(unavailable:)`). Whether the app is
/// online comes as a value from the root, which observes the monitor anyway.
///
/// Why it exists: `DownloadManager` republishes `phase` on every download
/// progress tick, re-rendering every OBSERVING view. When whole containers
/// (Home page, cards, cells) observed the globals directly, a single tick
/// re-rendered the entire surface. The visible v2.6 hitch, worst with a
/// 186-part book whose chapter list was re-validated per render. Now the
/// containers observe nothing; only this small scope (wrapping just the cover
/// that dims/badges) re-renders on a tick. It is a ONE-POINT system:
/// new cards/tiles inherit it and future availability fixes land in one place.
/// The download badge stays the separate, self-observing `CardDownloadBadge`.
struct MediaAvailabilityScope<Content: View>: View {
    let itemId: String
    /// Cell-cost sweep: cases whose "downloaded" notion is not a single item id
    /// (a show = any episode downloaded; a catalog tile = never) resolve it
    /// here. The scope stays THE one observing leaf either way.
    var isDownloadedOverride: (() -> Bool)? = nil
    @ViewBuilder var content: (_ unavailable: Bool) -> Content
    @ObservedObject private var downloadManager = DownloadManager.shared
    @Environment(\.isOnline) private var isOnline

    var body: some View {
        content(MediaAvailability.offlineUnavailable(
            isConnected: isOnline,
            isDownloaded: isDownloadedOverride?() ?? downloadManager.isDownloaded(itemId: itemId)))
    }
}
