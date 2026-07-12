import SwiftUI
import Combine

/// Große „Als Nächstes"-Karte (Apple Podcasts): Episoden-Cover mit Show-Badge,
/// darunter eine Textfläche in der Cover-Durchschnittsfarbe (weicher Übergang
/// aus dem Bild). Tap öffnet die Folgenseite; Play-Pille + Download liegen als
/// Overlay darüber und lösen daher keine Navigation aus.
struct PodcastFeaturedCard: View {
    let item: LibraryItem
    @ObservedObject var playerCoordinator: PlayerCoordinator
    @ObservedObject private var progress = PodcastProgressStore.shared
    @ObservedObject private var absPodcast = ABSPodcastProvider.shared
    @StateObject private var colorLoader = CoverColorLoader()
    private let width: CGFloat = 235

    private var coverURL: URL? { AppSession.shared.coverURL(forItemId: item.id) }
    private var isPlayed: Bool { podcastPlayState(for: item) == .played }

    /// Show-Cover nur als Badge zeigen, wenn es sich vom Episoden-Cover
    /// unterscheidet (sonst wäre es redundant).
    private var showBadgeURL: URL? {
        guard let show = AppSession.shared.rssProvider.show(forEpisodeId: item.id),
              let raw = show.artworkURL, let url = URL(string: raw), url != coverURL
        else { return nil }
        return url
    }

    var body: some View {
        NavigationLink {
            PodcastEpisodeDetailView(item: item, playerCoordinator: playerCoordinator)
        } label: {
            cardBody
        }
        .buttonStyle(.plain)
        .frame(width: width)
        .background(colorLoader.accent)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .task(id: coverURL) { await colorLoader.load(from: coverURL) }
        // Aktionen als Overlay → eigener Tap-Bereich, keine Navigation.
        .overlay(alignment: .bottomLeading) { playPill.padding(12) }
        .overlay(alignment: .bottomTrailing) {
            PodcastDownloadButton(item: item, tint: .white).padding(14)
        }
    }

    private var cardBody: some View {
        VStack(alignment: .leading, spacing: 0) {
            podcastArtwork(url: coverURL, size: width, corner: 0, thumbnailPixel: 800)
                .opacity(isPlayed ? 0.5 : 1)
                // Bild läuft weich in die Farbfläche aus (der „blurry" Seam).
                .overlay(alignment: .bottom) {
                    LinearGradient(colors: [.clear, colorLoader.accent],
                                   startPoint: .top, endPoint: .bottom)
                        .frame(height: width * 0.3)
                }
                .overlay(alignment: .bottomLeading) { showBadge }

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 4) {
                    if isPlayed { Image(systemName: "checkmark.circle.fill").font(.caption) }
                    Text(isPlayed ? String(localized: "Played") : relativeDateText(item))
                }
                .font(.caption).foregroundStyle(.white.opacity(0.85)).lineLimit(1)
                Text(item.title)
                    .font(.headline).foregroundStyle(.white).lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if let show = item.media?.metadata?.authorName {
                    Text(show).font(.subheadline).foregroundStyle(.white.opacity(0.85)).lineLimit(1)
                }
            }
            .padding(14)
            .padding(.bottom, 40)   // Platz für die Overlay-Pille/Download
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private var showBadge: some View {
        if let showBadgeURL {
            podcastArtwork(url: showBadgeURL, size: 44, corner: 8)
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(.white.opacity(0.6), lineWidth: 1))
                .padding(12)
        }
    }

    private var playPill: some View {
        Button {
            Task { await playerCoordinator.open(item: item) }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "play.fill").font(.caption)
                Text(durationText(item)).font(.subheadline.weight(.medium))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            // Solide, halbtransparente Kapsel statt Material-Blur — Blur ist
            // beim horizontalen Scrollen pro Frame teuer.
            .background(Capsule().fill(.white.opacity(0.22)))
        }
        .buttonStyle(.plain)
    }
}

/// Kompakte Show-Kachel für die Blättern-Reihe.
struct ShowTile: View {
    let show: PodcastShow
    private let size: CGFloat = 110

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            podcastArtwork(url: show.artworkURL.flatMap { URL(string: $0) }, size: size, corner: 12)
            Text(show.title)
                .font(.caption)
                .lineLimit(2)
                .frame(width: size, alignment: .leading)
        }
    }
}

/// Reiche Episoden-Zeile: Cover, Show + Titel, Datum/Restzeit, Fortschritt,
/// Play- und Download-Button. Tap spielt ab.
struct PodcastEpisodeRow: View {
    let item: LibraryItem
    @ObservedObject var playerCoordinator: PlayerCoordinator
    @ObservedObject private var progress = PodcastProgressStore.shared
    @ObservedObject private var absPodcast = ABSPodcastProvider.shared

    private var state: EpisodePlayState { podcastPlayState(for: item) }
    private var isPlayed: Bool { state == .played }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            podcastArtwork(url: AppSession.shared.coverURL(forItemId: item.id), size: 64, corner: 8)
                // Gehörte Folgen abgedimmt, wie in Apple Podcasts.
                .opacity(isPlayed ? 0.5 : 1)

            VStack(alignment: .leading, spacing: 3) {
                if let show = item.media?.metadata?.authorName {
                    Text(show.uppercased())
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Text(item.title)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(isPlayed ? .secondary : .primary)
                    .lineLimit(2)

                if case .inProgress(let fraction, _) = state {
                    // Angespielt: dünner Balken + Restzeit.
                    ProgressView(value: fraction)
                        .tint(AppTheme.accent)
                        .padding(.trailing, 40)
                        .padding(.top, 2)
                }

                HStack(spacing: 8) {
                    if isPlayed {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Text(metaText).font(.caption2).foregroundStyle(.secondary)
                    Spacer(minLength: 4)
                    PodcastDownloadButton(item: item)
                    playButton
                }
                .padding(.top, 1)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
        .onTapGesture { Task { await playerCoordinator.open(item: item) } }
        .contextMenu {
            Button {
                PodcastQueue.shared.playNext(item.id)
            } label: {
                Label("Play Next", systemImage: "text.insert")
            }
            Button {
                PodcastQueue.shared.playLast(item.id)
            } label: {
                Label("Play Last", systemImage: "text.append")
            }
            Button {
                podcastSetPlayed(item, !isPlayed)
            } label: {
                Label(
                    isPlayed ? String(localized: "Mark as Unplayed") : String(localized: "Mark as Played"),
                    systemImage: isPlayed ? "arrow.uturn.backward.circle" : "checkmark.circle"
                )
            }
        }
    }

    private var playButton: some View {
        Button {
            Task { await playerCoordinator.open(item: item) }
        } label: {
            Image(systemName: "play.circle.fill")
                .font(.title2)
                .foregroundStyle(AppTheme.accent)
        }
        .buttonStyle(.plain)
    }

    /// „vor 2 Tagen · 45 Min", „vor 2 Tagen · 12 Min übrig" bzw. „Abgespielt".
    private var metaText: String {
        var parts: [String] = []
        let date = relativeDateText(item)
        if !date.isEmpty { parts.append(date) }
        switch state {
        case .played:
            parts.append(String(localized: "Played"))
        case .inProgress(_, let remaining):
            parts.append(String(localized: "\(Int(remaining / 60)) min left"))
        case .unplayed:
            if let duration = item.media?.duration, duration > 0 {
                parts.append(durationText(item))
            }
        }
        return parts.joined(separator: " · ")
    }
}

/// Download-Steuerung für eine Podcast-Episode (Zustand aus dem DownloadManager):
/// Pfeil → Ring beim Laden → Häkchen wenn geladen. Wiederverwendet in Karte + Zeile.
struct PodcastDownloadButton: View {
    let item: LibraryItem
    /// Icon-Farbe — Default passt in Listen; auf farbigem/dunklem Grund `.white`.
    var tint: Color = .secondary
    @ObservedObject private var downloads = DownloadManager.shared

    var body: some View {
        if downloads.isDownloaded(itemId: item.id) {
            Image(systemName: "checkmark.circle")
                .font(.title3)
                .foregroundStyle(tint)
        } else if case .downloading(let f) = downloads.phase[item.id] {
            ProgressView(value: f).progressViewStyle(.circular).scaleEffect(0.7)
        } else {
            Button {
                Task {
                    guard let detail = try? await AppSession.shared.rssProvider.fetchItemDetail(itemId: item.id) else { return }
                    await DownloadManager.shared.download(item: detail, provider: AppSession.shared.rssProvider)
                }
            } label: {
                Image(systemName: "arrow.down.circle")
                    .font(.title3)
                    .foregroundStyle(tint)
            }
            .buttonStyle(.plain)
        }
    }
}

// MARK: - Wiedergabe-Zustand
