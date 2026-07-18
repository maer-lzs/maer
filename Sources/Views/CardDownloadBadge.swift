import SwiftUI

/// Unified download/offline status badge for the FeaturedCards, pinned to the
/// card's bottom-right corner (X6a/X6b). One component for the book AND podcast
/// cards so every card reads identically — the same badge family the grid tiles
/// use (dark disc + glyph, sized via CoverBadge):
/// - offline & not downloaded → wifi.slash
/// - downloading / paused → progress ring (tap cancels)
/// - downloaded → checkmark
/// - otherwise online → download arrow (tap runs the provider-specific start)
struct CardDownloadBadge: View {
    let itemId: String
    /// Card width — the badge sizes to it via CoverBadge (same as the grid tiles).
    var cardWidth: CGFloat = 235
    /// Provider-specific download start (the book vs podcast fetch differ).
    let startDownload: () async -> Void

    @ObservedObject private var downloads = DownloadManager.shared
    @ObservedObject private var networkMonitor = NetworkMonitor.shared

    private var isOfflineUnavailable: Bool {
        !networkMonitor.isConnected && !downloads.isDownloaded(itemId: itemId)
    }

    var body: some View {
        // X6c: cards get a smaller cap (~32) than the grid's 44 — the 22 % rule
        // ran a 235 pt card's badge into the 44 pt cap, which looked too fat.
        let disc = CoverBadge.size(tileWidth: cardWidth, cap: 32)
        content(disc: disc)
            .frame(width: max(44, disc), height: max(44, disc))
            .contentShape(Circle())
    }

    @ViewBuilder
    private func content(disc: CGFloat) -> some View {
        if isOfflineUnavailable {
            badge(disc) {
                Image(systemName: "wifi.slash").font(.system(size: disc * 0.42, weight: .semibold))
            }
        } else if let fraction = downloads.phase[itemId]?.progress {
            let paused: Bool = { if case .paused = downloads.phase[itemId] { return true } else { return false } }()
            Button { downloads.cancelDownload(itemId: itemId) } label: {
                badge(disc) {
                    ZStack {
                        UnifiedDownloadRing(fraction: fraction, lineWidth: 2.5, tint: .white)
                            .frame(width: disc * 0.55, height: disc * 0.55)
                        if paused {
                            Image(systemName: "pause.fill").font(.system(size: disc * 0.3, weight: .bold))
                        }
                    }
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Cancel Download"))
        } else if downloads.isDownloaded(itemId: itemId) {
            badge(disc) {
                Image(systemName: "checkmark").font(.system(size: disc * 0.42, weight: .bold))
            }
            .accessibilityLabel(Text("Downloaded"))
        } else if networkMonitor.isConnected {
            Button { Task { await startDownload() } } label: {
                badge(disc) {
                    Image(systemName: "arrow.down").font(.system(size: disc * 0.42, weight: .bold))
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Download"))
        }
    }

    private func badge<Content: View>(_ size: CGFloat, @ViewBuilder _ glyph: () -> Content) -> some View {
        ZStack {
            Circle().fill(.black.opacity(0.4)).frame(width: size, height: size)
            glyph().foregroundStyle(.white)
        }
    }
}
