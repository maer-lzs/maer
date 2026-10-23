// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import SwiftUI

/// Unified download/offline status badge for the FeaturedCards, pinned to the
/// card's bottom-right corner. One component for the book AND
/// podcast cards so every card reads identically. The badge matches
/// the card's OWN "Details" pill (the info pill in the same card row) BY
/// CONSTRUCTION. A capsule around subheadline-metric content with the pill's
/// 7 pt vertical padding, so both are always the same height, at every Dynamic
/// Type size. Solid semi-transparent fill, deliberately NO glass/blur (the
/// info pill's performance note applies: blur is expensive per frame during
/// horizontal scrolling). Iconography:
/// - offline & not downloaded → wifi.slash
/// - downloading / paused → progress ring (tap cancels)
/// - downloaded → the one `DownloadedMark` (the check means heard)
/// - otherwise nothing: downloading lives in the card's long-press menu
struct CardDownloadBadge: View {
    let itemId: String

    private let downloads = DownloadManager.shared
    @ObservedObject private var downloadStock = DownloadManager.stock
    @ObservedObject private var downloadProgress: ItemDownloadProgress

    init(itemId: String) {
        self.itemId = itemId
        _downloadProgress = ObservedObject(wrappedValue: DownloadManager.progress.item(itemId))
    }
    @Environment(\.isOnline) private var isOnline

    /// Ring diameter for the downloading state. Scaled relative to the
    /// subheadline metric so it tracks the pill height at accessibility sizes.
    @ScaledMetric(relativeTo: .subheadline) private var ringSize: CGFloat = 17

    private var isOfflineUnavailable: Bool {
        MediaAvailability.offlineUnavailable(isConnected: isOnline,
                                             isDownloaded: downloads.isDownloaded(itemId: itemId))
    }

    var body: some View {
        if isOfflineUnavailable {
            badge {
                Image(systemName: "wifi.slash").font(.subheadline.weight(.semibold))
                    .accessibilityLabel(Text("Not available offline"))
            }
        } else if let fraction = downloads.phase[itemId]?.progress {
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
            // Locale-independent handles: the three states must be tellable
            // apart without reading a translated label.
            .accessibilityIdentifier("download-cancel")
        } else if downloads.isDownloaded(itemId: itemId) {
            DownloadedMark(size: .large)
                .accessibilityIdentifier("download-done")
        }
        // Not downloaded: nothing. Downloading is an entry of the card's
        // long-press menu, never a sign on the card.
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
        .background(Capsule().fill(GlyphTone.fill))
        .frame(width: CoverBadge.detailControl, height: CoverBadge.detailControl,
               alignment: .bottomTrailing)
        .contentShape(Rectangle())
    }
}
