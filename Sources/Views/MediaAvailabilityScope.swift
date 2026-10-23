// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import SwiftUI

/// THE single observer of `DownloadManager` for a card or tile. It resolves
/// the pure `MediaAvailability.offlineUnavailable` predicate for ONE item and
/// hands the `unavailable` value to its content. Which stays value-driven
/// (the tiles' stacks of marks, `MediaTile(unavailable:)`). Whether the app is
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
    /// A tile that stands for SEVERAL downloads (a Mär playlist is its
    /// entries): available when any of them is here, and the content also
    /// learns whether ALL of them are, for its downloaded mark. Read here,
    /// where the stock is observed, so the tile needs no grip of its own.
    var anyOf: [String]? = nil
    private let content: (_ unavailable: Bool, _ allHere: Bool) -> Content
    private let downloadManager = DownloadManager.shared
    @ObservedObject private var downloadStock = DownloadManager.stock
    @Environment(\.isOnline) private var isOnline

    /// The one-download form every tile uses.
    init(itemId: String, isDownloadedOverride: (() -> Bool)? = nil,
         @ViewBuilder content: @escaping (_ unavailable: Bool) -> Content) {
        self.itemId = itemId
        self.isDownloadedOverride = isDownloadedOverride
        self.content = { unavailable, _ in content(unavailable) }
    }

    /// The several-downloads form (the playlist card).
    init(itemId: String, anyOf: [String],
         @ViewBuilder content: @escaping (_ unavailable: Bool, _ allHere: Bool) -> Content) {
        self.itemId = itemId
        self.anyOf = anyOf
        self.content = content
    }

    var body: some View {
        content(MediaAvailability.offlineUnavailable(isConnected: isOnline, isDownloaded: isHere),
                several?.allHere ?? false)
    }

    private var several: PlaylistPresentation.DownloadState? {
        anyOf.map { downloadManager.downloadState(of: $0) }
    }

    private var isHere: Bool {
        isDownloadedOverride?() ?? several?.anyHere ?? downloadManager.isDownloaded(itemId: itemId)
    }
}
