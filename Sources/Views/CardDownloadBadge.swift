import SwiftUI

/// Unified download/offline status badge for the FeaturedCards, pinned to the
/// card's bottom-right corner (X6a/X6b) — one component for the book AND
/// podcast cards so every card reads identically. X6f: the badge matches the
/// card's OWN "Details" pill (the info pill in the same card row): its height
/// and its solid, semi-transparent capsule fill. Deliberately NO glass/blur —
/// the info pill's performance note applies here too (blur is expensive per
/// frame during horizontal scrolling). Iconography:
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

    /// Visible badge size = the info pill's capsule height (subheadline text +
    /// 7 pt vertical padding ≈ 32) — badge and Details pill sit on one line at
    /// the same height. The TAP target stays `CoverBadge.detailControl` (44).
    private let side: CGFloat = 32

    var body: some View {
        content
            .frame(width: CoverBadge.detailControl, height: CoverBadge.detailControl)
            .contentShape(Circle())
    }

    @ViewBuilder
    private var content: some View {
        if isOfflineUnavailable {
            badge {
                Image(systemName: "wifi.slash").font(.system(size: side * 0.44, weight: .semibold))
            }
        } else if let fraction = downloads.phase[itemId]?.progress {
            let paused: Bool = { if case .paused = downloads.phase[itemId] { return true } else { return false } }()
            Button { downloads.cancelDownload(itemId: itemId) } label: {
                badge {
                    ZStack {
                        UnifiedDownloadRing(fraction: fraction, lineWidth: 2.5, tint: .white)
                            .frame(width: side * 0.55, height: side * 0.55)
                        if paused {
                            Image(systemName: "pause.fill").font(.system(size: side * 0.3, weight: .bold))
                        }
                    }
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Cancel Download"))
        } else if downloads.isDownloaded(itemId: itemId) {
            badge {
                Image(systemName: "checkmark").font(.system(size: side * 0.44, weight: .bold))
            }
            .accessibilityLabel(Text("Downloaded"))
        } else if networkMonitor.isConnected {
            Button { Task { await startDownload() } } label: {
                badge {
                    Image(systemName: "arrow.down").font(.system(size: side * 0.44, weight: .bold))
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Download"))
        }
    }

    /// The info pill's look: solid semi-transparent capsule, white glyph (the
    /// cards' bottom area is always cover/gradient — matches the pill's white
    /// text on `.white.opacity(0.22)`).
    private func badge<Content: View>(@ViewBuilder _ glyph: () -> Content) -> some View {
        glyph()
            .foregroundStyle(.white)
            .frame(width: side, height: side)
            .background(Capsule().fill(.white.opacity(0.22)))
    }
}
