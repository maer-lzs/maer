import SwiftUI

/// Unified download/offline status badge for the FeaturedCards, pinned to the
/// card's bottom-right corner (X6a/X6b). One component for the book AND podcast
/// cards so every card reads identically. X6e: the badge shares the DETAIL
/// pages' status-pill look and height — a glass capsule sized by
/// `CoverBadge.detailControl` — so card badge and detail pill read as one
/// family. Iconography:
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

    private var isOfflineUnavailable: Bool {
        !networkMonitor.isConnected && !downloads.isDownloaded(itemId: itemId)
    }

    /// One edge length for frame, hit target and glyph scaling — the detail
    /// pages' control size.
    private var side: CGFloat { CoverBadge.detailControl }

    var body: some View {
        content
            .frame(width: side, height: side)
            .contentShape(Circle())
    }

    @ViewBuilder
    private var content: some View {
        if isOfflineUnavailable {
            badge {
                Image(systemName: "wifi.slash").font(.system(size: side * 0.38, weight: .semibold))
            }
        } else if let fraction = downloads.phase[itemId]?.progress {
            let paused: Bool = { if case .paused = downloads.phase[itemId] { return true } else { return false } }()
            Button { downloads.cancelDownload(itemId: itemId) } label: {
                badge {
                    ZStack {
                        UnifiedDownloadRing(fraction: fraction, lineWidth: 2.5, tint: AppTheme.accent)
                            .frame(width: side * 0.5, height: side * 0.5)
                        if paused {
                            Image(systemName: "pause.fill").font(.system(size: side * 0.26, weight: .bold))
                        }
                    }
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Cancel Download"))
        } else if downloads.isDownloaded(itemId: itemId) {
            badge {
                Image(systemName: "checkmark").font(.system(size: side * 0.38, weight: .bold))
            }
            .accessibilityLabel(Text("Downloaded"))
        } else if networkMonitor.isConnected {
            Button { Task { await startDownload() } } label: {
                badge {
                    Image(systemName: "arrow.down").font(.system(size: side * 0.38, weight: .bold))
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Download"))
        }
    }

    /// The detail pill's glass-capsule look at the detail-control size (an
    /// equal-sided capsule renders as a disc, but material, stroke and primary
    /// glyph match the detail pages' controls — not the old dark disc).
    private func badge<Content: View>(@ViewBuilder _ glyph: () -> Content) -> some View {
        glyph()
            .foregroundStyle(.primary)
            .frame(width: side, height: side)
            .modifier(AdaptiveGlassBackground(shape: Capsule()))
    }
}
