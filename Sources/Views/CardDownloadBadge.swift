// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import SwiftUI

/// Unified download/offline status badge for the FeaturedCards, pinned to the
/// card's bottom-right corner (X6a/X6b). One component for the book AND
/// podcast cards so every card reads identically. X6f/X6g: the badge matches
/// the card's OWN "Details" pill (the info pill in the same card row) BY
/// CONSTRUCTION. A capsule around subheadline-metric content with the pill's
/// 7 pt vertical padding, so both are always the same height, at every Dynamic
/// Type size. Solid semi-transparent fill, deliberately NO glass/blur (the
/// info pill's performance note applies: blur is expensive per frame during
/// horizontal scrolling). Iconography:
/// - offline & not downloaded → wifi.slash
/// - downloading / paused → progress ring (tap cancels)
/// - downloaded → checkmark
/// - otherwise online → download arrow (tap runs the provider-specific start)
struct CardDownloadBadge: View {
    let itemId: String
    /// Provider-specific download start (the book vs podcast fetch differ).
    let startDownload: () async -> Void

    @ObservedObject private var downloads = DownloadManager.shared
    @ObservedObject private var networkMonitor = NetworkMonitor.shared

    /// Ring diameter for the downloading state. Scaled relative to the
    /// subheadline metric so it tracks the pill height at accessibility sizes.
    @ScaledMetric(relativeTo: .subheadline) private var ringSize: CGFloat = 17

    private var isOfflineUnavailable: Bool {
        !networkMonitor.isConnected && !downloads.isDownloaded(itemId: itemId)
    }

    var body: some View {
        if isOfflineUnavailable {
            badge {
                Image(systemName: "wifi.slash").font(.subheadline.weight(.semibold))
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
            badge {
                Image(systemName: "checkmark").font(.subheadline.weight(.bold))
            }
            .accessibilityLabel(Text("Downloaded"))
            .accessibilityIdentifier("download-done")
        } else if networkMonitor.isConnected {
            Button { Task { await startDownload() } } label: {
                badge {
                    Image(systemName: "arrow.down").font(.subheadline.weight(.bold))
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Download"))
            .accessibilityIdentifier("download-start")
        }
    }

    /// The info pill's construction: a capsule around subheadline-metric
    /// content with 7 pt vertical padding. A hidden subheadline text template
    /// gives the EXACT text line height the pill has, so badge and pill are
    /// height-identical by construction. The 44 pt tap frame (X6d hit-target
    /// constant) is anchored BOTTOM-TRAILING so the visible capsule sits at the
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
        .background(Capsule().fill(.white.opacity(0.22)))
        .frame(width: CoverBadge.detailControl, height: CoverBadge.detailControl,
               alignment: .bottomTrailing)
        .contentShape(Rectangle())
    }
}
