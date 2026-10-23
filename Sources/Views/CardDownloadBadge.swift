// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import SwiftUI

/// The one download manager both card views of this file ask.
private var cardDownloads: DownloadManager { DownloadManager.shared }

/// The download control of the FeaturedCards, pinned to the card's
/// bottom-right corner: the progress ring while a download runs or is
/// paused (a tap cancels), otherwise nothing. One component for the book AND
/// podcast cards. The ring matches the card's OWN "Details" pill BY
/// CONSTRUCTION: a capsule around subheadline-metric content with the pill's
/// 7 pt vertical padding, so both are always the same height, at every
/// Dynamic Type size. Solid semi-transparent tone, deliberately NO
/// glass/blur (blur is expensive per frame during horizontal scrolling).
/// Downloaded and not available offline are states, not controls: they
/// stand in the card's marks at the top right (`CardMarks`). Downloading
/// itself lives in the card's long-press menu.
struct CardDownloadBadge: View {
    let itemId: String

    private let downloads = cardDownloads
    @ObservedObject private var downloadStock = DownloadManager.stock
    @ObservedObject private var downloadProgress: ItemDownloadProgress

    init(itemId: String) {
        self.itemId = itemId
        _downloadProgress = ObservedObject(wrappedValue: DownloadManager.progress.item(itemId))
    }

    /// Ring diameter for the downloading state. Scaled relative to the
    /// subheadline metric so it tracks the pill height at accessibility sizes.
    @ScaledMetric(relativeTo: .subheadline) private var ringSize: CGFloat = 17

    var body: some View {
        if let fraction = downloads.phase[itemId]?.progress {
            let paused: Bool = { if case .paused = downloads.phase[itemId] { return true } else { return false } }()
            Button { downloads.cancelDownload(itemId: itemId) } label: {
                badge {
                    ZStack {
                        UnifiedDownloadRing(fraction: fraction, lineWidth: 2.5, tint: .white)
                            .frame(width: ringSize, height: ringSize)
                        if paused {
                            Image(systemName: "pause.fill")
                                .font(.system(size: ringSize * 0.55, weight: .bold))
                        }
                    }
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Cancel Download"))
            // Locale-independent handles: the states must be tellable apart
            // without reading a translated label.
            .accessibilityIdentifier("download-cancel")
        }
        // Not downloading: nothing in this corner.
    }

    /// The info pill's construction: a capsule around subheadline-metric
    /// content with 7 pt vertical padding. A hidden subheadline text template
    /// gives the EXACT text line height the pill has, so badge and pill are
    /// height-identical by construction. The 44 pt tap frame (the family's
    /// hit-target constant) is anchored BOTTOM-TRAILING so the visible capsule sits at the
    /// same 12 pt corner distance as the pill (a centered hit frame floated the
    /// badge 6 pt above the pill's baseline).
    private func badge<Content: View>(@ViewBuilder _ glyph: () -> Content) -> some View {
        ZStack {
            Text(verbatim: "X").font(.subheadline.weight(.medium)).hidden()
            glyph()
        }
        .foregroundStyle(.white)
        .padding(.vertical, 7)
        .padding(.horizontal, 9)
        .glyphCapsule()
        .frame(width: CoverBadge.detailControl, height: CoverBadge.detailControl,
               alignment: .bottomTrailing)
        .contentShape(Rectangle())
    }
}

/// The marks of a FeaturedCard at its top right, in the one stack of the
/// tiles: the kind in a mixed row (`stackedKind`), the lock of a feed, and
/// what availability says (`CoverAvailability.of`: downloaded, or not
/// available offline). Before, downloaded and offline stood as capsules in
/// the bottom-right corner beside the download ring. The one observing
/// leaf of the card's download state at the top.
struct CardMarks: View {
    let itemId: String
    /// The lock of the episode's feed; nil for what has no feed (a book).
    let lock: FeedLock?
    @Environment(\.coverGlyphKind) private var kind
    @Environment(\.isOnline) private var isOnline
    private let downloads = cardDownloads
    @ObservedObject private var downloadStock = DownloadManager.stock

    init(itemId: String, lock: FeedLock?) {
        self.itemId = itemId
        self.lock = lock
    }

    var body: some View {
        let downloaded = downloads.isDownloaded(itemId: itemId)
        let availability = CoverAvailability.of(
            failed: false, downloaded: downloaded,
            unavailable: MediaAvailability.offlineUnavailable(isConnected: isOnline, isDownloaded: downloaded))
        let locked = lock.map { $0 != .none } ?? false
        let marks: [CoverGlyph] = (kind == nil ? [] : [.kind]) + (locked ? [.lock] : [])
            + (availability == nil ? [] : [.availability])
        CoverGlyphStack(present: marks, coverSide: nil, cornerSide: 0,
                        label: { mark in
                            switch mark {
                            case .kind: Text(verbatim: kind?.label ?? "")
                            case .lock: lock == .refused ? Text("Access refused") : Text("Premium Feed")
                            default: availability == .downloaded ? Text("Downloaded") : Text("Not available offline")
                            }
                        }) { mark in
            switch mark {
            case .kind: if let kind { KindGlyph(kind: kind) }
            case .lock: if let lock { PremiumLockBadge(lock: lock) }
            default:
                if availability == .downloaded {
                    DownloadedMark(size: .large).padding(4)
                        .accessibilityIdentifier("download-done")
                } else {
                    OfflineUnavailableBadge().padding(5)
                }
            }
        }
    }
}
