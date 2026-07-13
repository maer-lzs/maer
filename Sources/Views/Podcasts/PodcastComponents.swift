import SwiftUI
import Combine

/// Large "Up Next" card (Apple Podcasts): episode cover with show badge, below
/// it a text area in the cover's average color (soft transition from the image).
/// Tapping the card resumes directly (Apple style); the info pill at the bottom
/// left opens the episode page, the download button sits at the bottom right —
/// both as overlays so they don't trigger the card tap.
struct PodcastFeaturedCard: View {
    let item: LibraryItem
    @ObservedObject var playerCoordinator: PlayerCoordinator
    @ObservedObject private var progress = PodcastProgressStore.shared
    @ObservedObject private var absPodcast = ABSPodcastProvider.shared
    @StateObject private var colorLoader = CoverColorLoader()
    private let width: CGFloat = 235

    private var coverURL: URL? { AppSession.shared.coverURL(forItemId: item.id) }
    private var isPlayed: Bool { podcastPlayState(for: item) == .played }

    /// Show the show cover as a badge only when it differs from the episode
    /// cover (otherwise it would be redundant).
    private var showBadgeURL: URL? {
        guard let show = AppSession.shared.rssProvider.show(forEpisodeId: item.id),
              let raw = show.artworkURL, let url = URL(string: raw), url != coverURL
        else { return nil }
        return url
    }

    var body: some View {
        // Tapping the card resumes directly (Apple style); detail via the info
        // pill at the bottom left.
        Button {
            Task { await playerCoordinator.open(item: item) }
        } label: {
            cardBody
        }
        .buttonStyle(.plain)
        .frame(width: width)
        .background(colorLoader.accent)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .task(id: coverURL) { await colorLoader.load(from: coverURL) }
        .overlay(alignment: .bottomLeading) { infoPill.padding(12) }
        .overlay(alignment: .bottomTrailing) {
            PodcastDownloadButton(item: item, tint: .white).padding(14)
        }
        .podcastEpisodeMenu(item: item, playerCoordinator: playerCoordinator)
    }

    /// Last played (relative) from local/ABS progress.
    private var lastPlayedText: String {
        let localTs = (UserDefaults.standard.array(forKey: AppStorageKeys.localPosition(item.id)) as? [Double])?.last ?? 0
        let absTs = absPodcast.episodeProgress[item.id]?.lastUpdate ?? 0
        let ts = max(localTs, absTs)
        guard ts > 0 else { return relativeDateText(item) }
        return Date(timeIntervalSince1970: ts / 1000).formatted(.relative(presentation: .named))
    }

    /// "12 min left" when in progress, otherwise the duration.
    private var remainingText: String {
        if case .inProgress(_, let remaining) = podcastPlayState(for: item), remaining > 0 {
            return String(localized: "\(Int(remaining / 60)) min left")
        }
        return durationText(item)
    }

    private var cardBody: some View {
        VStack(alignment: .leading, spacing: 0) {
            podcastArtwork(url: coverURL, size: width, corner: 0, thumbnailPixel: 800)
                .opacity(isPlayed ? 0.5 : 1)
                // The image fades softly into the color area (the "blurry" seam).
                .overlay(alignment: .bottom) {
                    LinearGradient(colors: [.clear, colorLoader.accent],
                                   startPoint: .top, endPoint: .bottom)
                        .frame(height: width * 0.3)
                }
                .overlay(alignment: .bottomLeading) { showBadge }

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 4) {
                    if isPlayed { Image(systemName: "checkmark.circle.fill").font(.caption) }
                    // Remaining · last played (formerly in the play pill) — for
                    // played episodes just "Played".
                    Text(isPlayed
                         ? String(localized: "Played")
                         : [remainingText, lastPlayedText].joined(separator: " · "))
                }
                .font(.caption).foregroundStyle(.white.opacity(0.85)).lineLimit(1)
                // Fixed heights for the variable lines (title 2 lines, show) —
                // otherwise a card with more text gets taller than its neighbours.
                Text(item.title)
                    .font(.headline).foregroundStyle(.white).lineLimit(2)
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .topLeading)
                Text(item.media?.metadata?.authorName ?? " ")
                    .font(.subheadline).foregroundStyle(.white.opacity(0.85)).lineLimit(1)
                    .frame(maxWidth: .infinity, minHeight: 20, alignment: .topLeading)
            }
            .padding(14)
            .padding(.bottom, 40)   // room for the overlay pill/download
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

    /// The card itself is tap-to-play; the pill therefore does NOT play again but
    /// opens the episode detail page (info).
    private var infoPill: some View {
        NavigationLink(value: PodcastRoute.episode(itemId: item.id)) {
            HStack(spacing: 6) {
                Image(systemName: "info.circle").font(.caption)
                Text("Details").font(.subheadline.weight(.medium))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            // Solid, semi-transparent capsule instead of material blur — blur is
            // expensive per frame during horizontal scrolling.
            .background(Capsule().fill(.white.opacity(0.22)))
        }
        .buttonStyle(.plain)
    }
}

/// Compact show tile for the browse row.
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

/// Rich episode row: cover, show + title, date/remaining time, progress,
/// play and download button. Playing runs via the play button; whole-row
/// tap-to-play is opt-in (`tapToPlay`) — the show page turns it off so only the
/// button plays.
struct PodcastEpisodeRow: View {
    let item: LibraryItem
    /// Whether tapping anywhere on the row plays it (queue/inbox); off on the
    /// show page, where only the play button plays.
    var tapToPlay: Bool = true
    @ObservedObject var playerCoordinator: PlayerCoordinator
    @ObservedObject private var progress = PodcastProgressStore.shared
    @ObservedObject private var absPodcast = ABSPodcastProvider.shared
    @ObservedObject private var downloads = DownloadManager.shared

    private var state: EpisodePlayState { podcastPlayState(for: item) }
    private var isPlayed: Bool { state == .played }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            podcastArtwork(url: AppSession.shared.coverURL(forItemId: item.id), size: 64, corner: 8)
                // Played episodes dimmed, as in Apple Podcasts.
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
                    // In progress: thin bar + remaining time.
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
                    infoButton
                    PodcastDownloadButton(item: item)
                }
                .padding(.top, 1)
            }
            playButton
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
        .onTapGesture { if tapToPlay { Task { await playerCoordinator.open(item: item) } } }
        .podcastEpisodeMenu(item: item, playerCoordinator: playerCoordinator)
        // Swipe actions apply in `List` contexts (show page, queue); in pure
        // `LazyVStack` previews the context menu remains.
        .swipeActions(edge: .leading, allowsFullSwipe: true) {
            Button {
                PodcastQueue.shared.playNext(item.id)
            } label: {
                Label("Play Next", systemImage: "text.insert")
            }
            .tint(AppTheme.accent)
            Button {
                PodcastQueue.shared.playLast(item.id)
            } label: {
                Label("Play Last", systemImage: "text.append")
            }
            .tint(.gray)
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button {
                podcastSetPlayed(item, !isPlayed)
            } label: {
                Label(
                    isPlayed ? String(localized: "Mark as Unplayed") : String(localized: "Mark as Played"),
                    systemImage: isPlayed ? "arrow.uturn.backward.circle" : "checkmark.circle"
                )
            }
            .tint(.green)
            if downloads.isDownloaded(itemId: item.id) {
                Button(role: .destructive) {
                    DownloadManager.shared.deleteDownload(itemId: item.id)
                } label: {
                    Label("Delete Download", systemImage: "trash")
                }
            } else {
                Button {
                    Task {
                        let provider = AppSession.shared.provider(for: item.id)
                        if let detail = try? await provider.fetchItemDetail(itemId: item.id) {
                            await DownloadManager.shared.download(item: detail, provider: provider)
                        }
                    }
                } label: {
                    Label("Download", systemImage: "arrow.down.circle")
                }
                .tint(.blue)
            }
        }
    }

    private var playButton: some View {
        Button {
            Task {
                if isPlayed {
                    // A finished episode replays from the beginning and is set
                    // back to unplayed. `restart` starts at 0 and writes it
                    // through on every source (server + iCloud/gpodder); the
                    // local flip updates the row immediately.
                    podcastSetPlayed(item, false)
                    await playerCoordinator.open(item: item, restart: true)
                } else {
                    await playerCoordinator.open(item: item)
                }
            }
        } label: {
            Image(systemName: "play.circle.fill")
                .font(.system(size: 38))
                .foregroundStyle(.primary)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("Play"))
    }

    /// Opens the episode detail page (info) — value-based so the media tab can
    /// pop back to the library.
    private var infoButton: some View {
        NavigationLink(value: PodcastRoute.episode(itemId: item.id)) {
            Image(systemName: "info.circle")
                .font(.body)
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("Details"))
    }

    /// "2 days ago · 45 min", "2 days ago · 12 min left" or "Played".
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

/// Download control for a podcast episode (state from the DownloadManager):
/// arrow → ring while loading → checkmark when downloaded. Reused in card + row.
struct PodcastDownloadButton: View {
    let item: LibraryItem
    /// Icon color — the default fits in lists; use `.white` on a colored/dark background.
    var tint: Color = .secondary
    @ObservedObject private var downloads = DownloadManager.shared

    var body: some View {
        if downloads.isDownloaded(itemId: item.id) {
            Image(systemName: "checkmark.circle")
                .font(.title3)
                .foregroundStyle(tint)
                .accessibilityLabel(Text("Downloaded"))
        } else if case .downloading(let f) = downloads.phase[item.id] {
            ProgressView(value: f).progressViewStyle(.circular).scaleEffect(0.7)
                .accessibilityLabel(Text("Downloading"))
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
            .accessibilityLabel(Text("Download"))
        }
    }
}

// MARK: - Playback state
