// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import SwiftUI
import Combine

/// Large "Up Next" card (Apple Podcasts): episode cover with show badge, below
/// it a text area in the cover's average color (soft transition from the image).
/// Tapping the card resumes directly (Apple style); the info pill at the bottom
/// left opens the episode page, the download button sits at the bottom right.
/// Both as overlays so they don't trigger the card tap.
struct PodcastFeaturedCard: View {
    @Environment(\.itemRouter) private var router
    let item: LibraryItem
    /// Cell-cost sweep: the CARD carries no global observers. Every cell
    /// creation used to set up 5 subscriptions (the per-cell bump). State is
    /// read plain; refresh comes from the hosts' coarse recompute (gated
    /// section applies), the offline dim from the MediaAvailabilityScope LEAF
    /// around the artwork, live download state from CardDownloadBadge.
    let playerCoordinator: PlayerCoordinator
    @StateObject private var colorLoader = CoverColorLoader()
    private let width = CardMetrics.featuredCardWidth
    // The overlay pill and the fixed line heights scale with Dynamic
    // Type. At AX sizes the pill used to grow into the text block.
    @ScaledMetric(relativeTo: .subheadline) private var pillReserve: CGFloat = 40
    @ScaledMetric(relativeTo: .headline) private var titleMinHeight: CGFloat = 44
    @ScaledMetric(relativeTo: .subheadline) private var showMinHeight: CGFloat = 20

    private var coverURL: URL? { router.coverURL(item.id) }
    private var isPlayed: Bool { podcastPlayState(for: item) == .played }

    /// Show the show cover as a badge only when it differs from the episode
    /// cover (otherwise it would be redundant).
    private var showBadgeURL: URL? {
        guard let show = PodcastShowSources.show(forEpisodeId: item.id),
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
        // The Continue card is the row's witness: a journey proves that an
        // entry arriving from outside lands here by itself.
        .accessibilityIdentifier("podcast-continue-\(item.id)")
        .frame(width: width)
        .background(colorLoader.accent)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        // Fixed-width eye-catcher card: cap the type size at AX4/AX5.
        .dynamicTypeSize(...DynamicTypeSize.accessibility1)
        .task(id: coverURL) { await colorLoader.load(from: coverURL) }
        .overlay(alignment: .bottomLeading) { infoPill.padding(12) }
        // The Continue card carries the lock too. A free and a
        // premium copy of the SAME show can sit next to each other here
        //, and then the mark tells them apart. It sits
        // on the COVER (the card's cover fills the top), never at the text;
        // the bottom corners carry the info pill and the download badge.
        .overlay(alignment: .topTrailing) {
            PremiumLockBadge(isPremium: PodcastSubscriptions.isPremiumFeed(
                PodcastShowSources.show(forEpisodeId: item.id)?.feedURL ?? ""))
        }
        // X6b: the SHARED download/offline badge family at the card corner.
        // Identical to the book card (was PodcastDownloadButton before).
        .overlay(alignment: .bottomTrailing) {
            CardDownloadBadge(itemId: item.id, startDownload: {
                // The episode's OWN source, not „RSS" by name: an ABS
                // episode carries an `abspod:` id, the RSS store is indexed by
                // its own guids, and asking it for a foreign id found nothing.
                // The guard below then returned, so the badge did nothing and
                // said nothing.
                await DownloadManager.shared.startDownload(itemId: item.id, kind: .podcasts)
            })
            .padding(12)
        }
        .podcastEpisodeMenu(item: item, playerCoordinator: playerCoordinator,
                            showsContinueHide: true)
    }

    /// Last played (relative) from local/ABS progress.
    private var lastPlayedText: String {
        // The ONE moment the Home row ranks by as well.
        switch ListeningMoment.label(
            local: ProgressMark.timestamp(ListeningStore.backup(item.id)) ?? 0,
            server: ABSPodcastProvider.shared.episodeProgress[item.id]?.lastUpdate ?? 0,
            playingNowMs: PlayingNow.momentMs(forId: item.id)) {
        case .playing: return String(localized: "Playing now")
        case .at(let ts): return Date(timeIntervalSince1970: ts / 1000).formatted(.relative(presentation: .named))
        case .none: return relativeDateText(item)
        }
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
            // S14/A6 + sweep: the offline dim resolves in the ONE observing
            // leaf (MediaAvailabilityScope). The card itself stays plain.
            MediaAvailabilityScope(itemId: item.id) { unavailable in
                podcastArtwork(url: coverURL, size: width, corner: 0, thumbnailPixel: 800)
                    // X6b: cover still dims when played/offline; the wifi.slash
                    // marker lives in the card-corner badge (CardDownloadBadge).
                    .opacity(isPlayed || unavailable ? 0.5 : 1)
            }
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
                    // Remaining · last played (formerly in the play pill). For
                    // played episodes just "Played".
                    Text(isPlayed
                         ? String(localized: "Played")
                         : [remainingText, lastPlayedText].joined(separator: " · "))
                }
                .font(.caption).foregroundStyle(.white.opacity(0.85)).lineLimit(1)
                // Fixed heights for the variable lines (title 2 lines, show).
                // Otherwise a card with more text gets taller than its neighbours.
                Text(item.title)
                    .font(.headline).foregroundStyle(.white).lineLimit(2)
                    .frame(maxWidth: .infinity, minHeight: titleMinHeight, alignment: .topLeading)
                Text(item.media?.metadata?.authorName ?? " ")
                    .font(.subheadline).foregroundStyle(.white.opacity(0.85)).lineLimit(1)
                    .frame(maxWidth: .infinity, minHeight: showMinHeight, alignment: .topLeading)
            }
            .padding(14)
            .padding(.bottom, pillReserve)   // room for the overlay pill/download
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
        // Shared anatomy (5219a7). One Details pill for every card family.
        CardDetailPill(value: PodcastRoute.episode(itemId: item.id))
    }
}

/// Recently-updated show tile: cover with a new-episode count badge, the show
/// title and the relative update time. Shared by the podcast tab's "Recently
/// Updated" grid and Home's "Latest Episodes" shelf. Tapping is the
/// caller's NavigationLink → the show page.
struct RecentShowTile: View {
    let info: RecentShowInfo
    /// The app-wide choice for the number on the tile.
    @AppStorage(AppStorageKeys.podcastTileCountMode) private var tileCountMode = PodcastTileCount.standard.rawValue

    var body: some View {
        // Cell-cost sweep: the tile carries no global observers. The show-level
        // "any episode downloaded" dim resolves in the MediaAvailabilityScope
        // leaf (custom resolve), same convention as the featured cards.
        MediaAvailabilityScope(
            itemId: info.show.id,
            isDownloadedOverride: { [episodes = info.show.episodes] in
                episodes.contains { DownloadManager.shared.isDownloaded(itemId: $0.guid) }
            }
        ) { unavailable in
            tileBody(unavailable: unavailable)
        }
    }

    private func tileBody(unavailable: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .topTrailing) {
                CachedAsyncImage(url: info.show.artworkURL.flatMap { URL(string: $0) }, useThumbnail: true) { image, pixels in
                    CoverFitting(image: image, pixelSize: pixels, backdrop: .neutral)
                } placeholder: {
                    Rectangle().fill(.quaternary)
                        .overlay(Image(systemName: "mic").foregroundStyle(.secondary))
                }
                .aspectRatio(1, contentMode: .fit)
                .frame(maxWidth: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .opacity(unavailable ? 0.5 : 1)
                .overlay(alignment: .topLeading) {
                    if unavailable {
                        Image(systemName: "wifi.slash")
                            .font(.caption)
                            .foregroundStyle(.white, .secondary)
                            .padding(8)
                    }
                }
                // THE premium badge (shared component).
                .premiumLock(PodcastSubscriptions.isPremiumFeed(info.show.feedURL))

                if let count = PodcastTileCount.mode(raw: tileCountMode)
                    .badge(unplayed: info.unplayedCount, newSinceLastPlayed: info.newCount) {
                    Text("\(count)")
                        .font(.caption2.bold()).foregroundStyle(.white)
                        .padding(.horizontal, 7).padding(.vertical, 3)
                        .background(Capsule().fill(.red))
                        .padding(7)
                        .accessibilityIdentifier("show-tile-count")
                }
            }
            Text(info.show.title)
                .font(.subheadline.bold())
                .foregroundStyle(.primary)
                .lineLimit(1)
            Text(Date(timeIntervalSince1970: info.lastUpdated / 1000)
                    .formatted(.relative(presentation: .named)))
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }
}


/// Compact show tile for the browse row.
struct ShowTile: View {
    let show: PodcastShow
    // The fixed tile width stays, but accessibility sizes get more
    // lines so titles remain readable instead of truncating to a fragment.
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    private let size: CGFloat = 110

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            podcastArtwork(url: show.artworkURL.flatMap { URL(string: $0) }, size: size, corner: 12)
                // Same shared badge as the recent-shows grid.
                .premiumLock(PodcastSubscriptions.isPremiumFeed(show.feedURL))
            Text(show.title)
                .font(.caption)
                // Jank convention: reserved lines. A short title must not
                // shrink the tile (variable LazyVGrid heights bump the scroll).
                .lineLimit(dynamicTypeSize.isAccessibilitySize ? 4 : 2, reservesSpace: true)
                .frame(width: size, alignment: .leading)
        }
    }
}

/// What tapping the row body (cover + text) does. The trailing controls
/// (info / download / play) are always separate and work in every mode.
enum PodcastRowTap { case play, detail, none }

/// Rich episode row: cover, show + title, date/remaining time, progress, and a
/// trailing cluster of consistent gray controls (info · download · play/pause).
/// The origin capsule. A GENERIC video SF symbol plus the platform name as
/// a descriptive provenance line, never a trademark glyph. The word is the
/// carrier; the symbol is Beiwerk with a fallback ladder (film → tv →
/// word-only). Carried by `PodcastShow.origin` only,
/// never a URL heuristic. Placed on surfaces OUTSIDE the group row (latest
/// episodes, downloads, search, show page). Inside the group the heading
/// already says it.
struct OriginCapsule: View {
    /// Compact = height-neutral for reserved-height list rows (jank rule:
    /// cell height must not depend on this row's data).
    var compact: Bool = false
    /// The provenance word. The row capsule of the music rows carries a
    /// server's name here while two music servers are active (F5b-4); the
    /// default is the video platform, as before.
    var text: String = "YouTube"
    /// Beiwerk to the word; nil for a word-only capsule.
    var systemImage: String? = "play.rectangle"

    var body: some View {
        HStack(spacing: 3) {
            if let systemImage { Image(systemName: systemImage).font(.caption2) }
            Text(verbatim: text).font(.caption2.weight(.medium))
        }
        .padding(.horizontal, compact ? 4 : 6)
        .padding(.vertical, compact ? 0 : 2)
        .background(.quaternary, in: Capsule())
        .foregroundStyle(.secondary)
        .accessibilityLabel(Text(verbatim: text))
    }
}

struct PodcastEpisodeRow: View {
    @Environment(\.itemRouter) private var router
    let item: LibraryItem
    /// Tapping the row body opens the episode page on every surface (show
    /// list, downloads, queue); the large play button handles playback.
    var rowTap: PodcastRowTap = .detail
    /// Cell-cost sweep: the ROW carries no global observers (5 subscriptions
    /// per row creation were the per-cell bump). Plain reads; hosts re-render
    /// coarsely (PodcastsRecomputeScope / section applies), the play glyph
    /// lives in the observing EpisodeRowPlayButton leaf, live download state
    /// in PodcastDownloadButton.
    let playerCoordinator: PlayerCoordinator
    /// The hosting SHOW page passes its title so the eyebrow can
    /// drop when it merely repeats it; surfaces that mix shows pass nil.
    var showTitle: String? = nil
    /// The HOST resolves membership once (set lookup). A per-row
    /// shows×episodes scan would break the cell-cost convention.
    var showsOriginCapsule: Bool = false
    /// Whether this surface may download. The page resolves it ONCE from its
    /// state and hands the value down, like the origin capsule: an episode of
    /// a show nobody subscribed to has no download control at all rather than
    /// a disabled one.
    var showsDownload: Bool = true
    @Environment(\.pushPodcastRoute) private var pushRoute
    @Environment(\.isOnline) private var isOnline

    /// Text-only episode (kept, no enclosure). Plain read, one per render.
    private var isTextOnly: Bool {
        !PodcastSubscriptions.shared.isPlayableEpisode(itemId: item.id)
    }

    var body: some View {
        // Resolve the play state ONCE per render. It deserializes UserDefaults,
        // and the row used to read it 3-4 times per body evaluation.
        let state = podcastPlayState(for: item)
        let isPlayed = state == .played
        let textOnly = isTextOnly
        HStack(alignment: .center, spacing: 2) {
            // No Spacer next to the max-width row body. Two equally
            // flexible siblings made SwiftUI split the width and pushed the
            // trailing icons to the middle (visible in the show page's List).
            rowBody(state: state, isPlayed: isPlayed)
                .layoutPriority(1)
            // Trailing controls: download + the large play button. Info is
            // gone. The whole row body opens the episode page instead.
            // Text-only rows keep the SLOTS (cell-height convention) but
            // render them invisible. No play/download affordance.
            if showsDownload {
                PodcastDownloadButton(item: item, showsDownloadedState: false)
                    .opacity(textOnly ? 0 : 1)
                    .allowsHitTesting(!textOnly)
            }
            EpisodeRowPlayButton(item: item, playerCoordinator: playerCoordinator)
                .opacity(textOnly ? 0 : 1)
                .allowsHitTesting(!textOnly)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
        .podcastEpisodeMenu(item: item, playerCoordinator: playerCoordinator)
        // Swipe actions apply in `List` contexts (show page, queue); in pure
        // `LazyVStack` previews the context menu remains. Text-only rows
        // offer no queue swipes (never queueable).
        .swipeActions(edge: .leading, allowsFullSwipe: true) {
            if !textOnly {
                Button {
                    PlayQueue.shared.playNext(item.id)
                } label: {
                    Label("Play Next", systemImage: "text.insert")
                }
                .tint(AppTheme.accent)
                Button {
                    PlayQueue.shared.playLast(item.id)
                } label: {
                    Label("Play Last", systemImage: "text.append")
                }
                AddToPlaylistButton(itemId: item.id,
                                    knownTitles: [item.id: item.title])
                .tint(.gray)
            }
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
            if DownloadManager.shared.isDeletableDownload(itemId: item.id) {
                Button(role: .destructive) {
                    DownloadManager.shared.deleteDownload(itemId: item.id)
                } label: {
                    Label("Delete Download", systemImage: "trash")
                }
            } else if MediaDownloadOffer.isPossible(router.provider(item.id).capabilities) {
                Button {
                    Task { await DownloadManager.shared.startDownload(itemId: item.id, kind: .podcasts) }
                } label: {
                    Label("Download", systemImage: "arrow.down.circle")
                }
                .tint(.blue)
            }
        }
    }

    /// Tappable row body (cover + text). Behaviour depends on `rowTap`; the
    /// trailing controls stay separate so they always receive their own taps.
    @ViewBuilder private func rowBody(state: EpisodePlayState, isPlayed: Bool) -> some View {
        switch rowTap {
        case .play:
            // A text-only episode cannot start. Its tap opens the notes.
            if isTextOnly {
                Button {
                    pushRoute(.episode(itemId: item.id))
                } label: {
                    rowContent(state: state, isPlayed: isPlayed)
                }
                .buttonStyle(.plain)
            } else {
            Button { Task { await playerCoordinator.open(item: item) } } label: {
                rowContent(state: state, isPlayed: isPlayed)
            }
            .buttonStyle(.plain)
            }
        case .detail:
            Button {
                pushRoute(.episode(itemId: item.id))
            } label: {
                rowContent(state: state, isPlayed: isPlayed)
            }
            .buttonStyle(.plain)
        case .none:
            rowContent(state: state, isPlayed: isPlayed)
        }
    }

    /// Offline and not downloaded: the row cannot start playback. The online
    /// answer comes as a value from the root; the download state stays a
    /// plain read, because the hosting page observes it once per page and
    /// not once per row.
    private var isOfflineUnavailable: Bool {
        MediaAvailability.offlineUnavailable(
            isConnected: isOnline,
            isDownloaded: DownloadManager.shared.isDownloaded(itemId: item.id))
    }

    private func rowContent(state: EpisodePlayState, isPlayed: Bool) -> some View {
        let inProgress: Double? = { if case .inProgress(let f, _) = state { return f } else { return nil } }()
        return MediaRowContent(
            coverURL: router.coverURL(item.id),
            eyebrow: PodcastWorkOrder.eyebrow(author: item.media?.metadata?.authorName,
                                              showTitle: showTitle),
            title: item.title,
            titleDimmed: isPlayed || isTextOnly,
            coverDimmed: isPlayed || isOfflineUnavailable || isTextOnly,
            offlineBadge: isOfflineUnavailable,
            downloadedBadge: DownloadManager.shared.isDownloaded(itemId: item.id),
            progressFraction: inProgress,
            meta: metaText(state: state),
            showsPlayedCheck: isPlayed,
            placeholderSystemImage: "mic",
            showsOriginCapsule: showsOriginCapsule
        )
    }

    /// "2 days ago · 45 min", "2 days ago · 12 min left" or "Played".
    private func metaText(state: EpisodePlayState) -> String {
        var parts: [String] = []
        let date = relativeDateText(item)
        if !date.isEmpty { parts.append(date) }
        // Mark the text-only row instead of showing play/duration meta.
        if isTextOnly {
            parts.append(String(localized: "Text only"))
            return parts.joined(separator: " · ")
        }
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

/// The row's play/pause glyph. The ONE observing leaf of the row (the glyph
/// must flip live while THIS episode plays; the row itself stays plain).
struct EpisodeRowPlayButton: View {
    let item: LibraryItem
    @ObservedObject var playerCoordinator: PlayerCoordinator

    private var isCurrent: Bool { playerCoordinator.activeItem?.id == item.id }
    private var isPlayingThis: Bool { isCurrent && playerCoordinator.isPlaying }

    var body: some View {
        Button { Task { await tapped() } } label: {
            Image(systemName: isPlayingThis ? "pause.circle.fill" : "play.circle.fill")
                .font(.system(size: 30))
                .foregroundStyle(.secondary)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isPlayingThis ? Text("Pause") : Text("Play"))
        // Locale-independent handle: the label above is translated, and a
        // measurement that searches an English word measures the locale.
        .accessibilityIdentifier("episode-row-play")
    }

    private func tapped() async {
        if isPlayingThis {
            playerCoordinator.viewModel?.pause()
        } else if isCurrent {
            playerCoordinator.viewModel?.play()
        } else if podcastPlayState(for: item) == .played {
            // Replay a finished episode from the beginning + mark unplayed.
            // `restart` writes 0 through on every source (server + iCloud/gpodder).
            podcastSetPlayed(item, false)
            await playerCoordinator.open(item: item, restart: true)
        } else {
            await playerCoordinator.open(item: item)
        }
    }
}

/// Download control for a podcast episode (state from the DownloadManager):
/// arrow → ring while loading → filled arrow when downloaded. Reused in card + row.
struct PodcastDownloadButton: View {
    @Environment(\.itemRouter) private var router
    let item: LibraryItem
    /// Icon color. The default fits in lists; use `.white` on a colored/dark background.
    var tint: Color = .secondary
    /// Rows show the downloaded state on the artwork instead. They pass
    /// false and this control collapses once the download finished.
    var showsDownloadedState = true
    private let downloads = DownloadManager.shared
    @ObservedObject private var downloadStock = DownloadManager.stock
    @ObservedObject private var downloadProgress: ItemDownloadProgress
    @Environment(\.isOnline) private var isOnline

    init(item: LibraryItem, tint: Color = .secondary, showsDownloadedState: Bool = true) {
        self.item = item
        self.tint = tint
        self.showsDownloadedState = showsDownloadedState
        _downloadProgress = ObservedObject(wrappedValue: DownloadManager.progress.item(item.id))
    }

    var body: some View {
        if downloads.isDownloaded(itemId: item.id) {
            if showsDownloadedState {
                // The filled arrow means stored; the check means heard.
                Image(systemName: "arrow.down.circle.fill")
                    .font(.title3)
                    .foregroundStyle(tint)
                    .frame(width: CoverBadge.detailControl, height: CoverBadge.detailControl)
                    .accessibilityLabel(Text("Downloaded"))
            }
        } else if case .downloading(let f) = downloads.phase[item.id] {
            // Tapping the running ring cancels, like the album download button.
            Button {
                DownloadManager.shared.cancelDownload(itemId: item.id)
            } label: {
                DownloadRing(fraction: f)
                    .frame(width: CoverBadge.detailControl, height: CoverBadge.detailControl)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Cancel Download"))
        } else if isOnline {
            // Offline a download can't start. Hide the control entirely.
            Button {
                Task {
                    // Same reason as the featured card: ask the episode's
                    // own source. This button sits on ABS episodes too.
                    await DownloadManager.shared.startDownload(itemId: item.id, kind: .podcasts)
                }
            } label: {
                Image(systemName: "arrow.down.circle")
                    .font(.title3)
                    .foregroundStyle(tint)
                    .frame(width: CoverBadge.detailControl, height: CoverBadge.detailControl)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Download"))
            .accessibilityIdentifier("episode-row-download")
        }
    }
}

// MARK: - Playback state

// MARK: - Inline subscribe control (Discover)

/// Shared inline subscribe control. The podcast tab's Discover grid and the
/// Home Discover row use the SAME flow: a green check when already
/// subscribed, a spinner while subscribing, otherwise a "+" that subscribes on
/// the ABS server when ABS podcasts are active, else locally + gpodder push.
struct PodcastSubscribeBadge: View {
    let feedURL: String
    @ObservedObject private var subs = PodcastSubscriptions.shared
    @ObservedObject private var absPodcast = ABSPodcastProvider.shared
    @State private var subscribing = false

    var body: some View {
        if Self.isSubscribed(feedURL) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.white, .green)
                .background(Circle().fill(.black.opacity(0.25)))
        } else if subscribing {
            ProgressView().controlSize(.small)
                .padding(4).background(Circle().fill(.black.opacity(0.35)))
        } else {
            Button {
                subscribing = true
                Task {
                    await Self.subscribe(feedURL)
                    subscribing = false
                }
            } label: {
                Image(systemName: "plus.circle.fill")
                    .font(.title3)
                    .foregroundStyle(.white, AppTheme.accent)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Subscribe"))
        }
    }

    /// Already subscribed (locally OR on the server). Normalized feed URL.
    static func isSubscribed(_ feedURL: String) -> Bool {
        PodcastShowSources.isSubscribed(feedURL: feedURL)
    }

    static func subscribe(_ feedURL: String) async {
        if AppStorageKeys.absPodcastsEnabledValue, ABSPodcastProvider.shared.hasPodcasts {
            _ = await ABSPodcastProvider.shared.subscribeOnServer(feedURL: feedURL)
        } else {
            _ = await PodcastSubscriptions.shared.subscribe(urlString: feedURL)
            await GPodderSync.shared.reconcile()   // push the new subscription to the server
        }
        PodcastRecommendationsStore.shared.remove(feedURL: feedURL)
        // A subscription takes the show over. From here the subscription store
        // answers for its episodes, so the browsed halves step aside instead of
        // becoming a second truth about the same feed. Both halves go by the
        // FEED: the server branch has no local show to find, and the feed is
        // what the person subscribed to, under whatever scheme or query it
        // was browsed.
        BrowsedEpisodes.shared.forget(feedURL: feedURL)
        BrowsedEpisodes.shared.forgetListened(feedURL: feedURL)
    }
}

/// The subscribe badge's big sibling for the show page. Same family, same
/// statics, capsule form with a label.
struct PodcastSubscribeButton: View {
    let feedURL: String
    @ObservedObject private var subs = PodcastSubscriptions.shared
    @ObservedObject private var absPodcast = ABSPodcastProvider.shared
    @State private var subscribing = false

    var body: some View {
        if PodcastSubscribeBadge.isSubscribed(feedURL) {
            Label("Subscribed", systemImage: "checkmark.circle.fill")
                .font(.headline)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(Capsule().fill(.quaternary))
        } else {
            Button {
                subscribing = true
                Task {
                    await PodcastSubscribeBadge.subscribe(feedURL)
                    subscribing = false
                }
            } label: {
                Group {
                    if subscribing {
                        ProgressView().tint(.white)
                    } else {
                        Label("Subscribe", systemImage: "plus.circle.fill").font(.headline)
                    }
                }
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(Capsule().fill(AppTheme.accent))
            }
            .buttonStyle(.plain)
        }
    }
}

/// Y2a: ONE recommendation tile for Home's Discover row AND the podcast tab's
/// Recommended row. A MediaTile with the subscribe corner control;
/// the tile tap opens the temporary show preview.
struct RecommendationTile: View {
    let result: PodcastSearchResult
    var subtitle: String? = nil
    /// X²·1: the CC capsule of a curated independent feed. Only where the
    /// FEED states the licence (rides MediaTile's badge mechanics).
    var badgeText: String? = nil
    /// nil = the tile FILLS its containerRelativeFrame slot
    /// (screen-relative rows); a numeric width remains for legacy callers.
    var width: CGFloat? = nil
    @Environment(\.pushPodcastRoute) private var pushRoute
    var body: some View {
        // A3 + sweep: catalog tiles need the net (preview + subscribe). The
        // offline dim resolves in the scope leaf (never "downloaded"), the
        // tile itself carries no observer.
        MediaAvailabilityScope(itemId: result.feedURL, isDownloadedOverride: { false }) { unavailable in
            MediaTile(
                title: result.title,
                subtitle: subtitle,
                coverURL: result.artworkURL.flatMap { URL(string: $0) },
                unavailable: unavailable,
                badgeText: badgeText,
                // A result WITHOUT artwork resolves it from the feed. The
                // same fallback the old LIST row had; without
                // it every curated feed tile rendered gray (curation carries
                // no artworkURL by design).
                coverOverride: result.artworkURL == nil
                    ? FeedArtwork(feedURL: result.feedURL, placeholderSystemImage: "waveform.and.mic")
                    : nil,
                onTap: { pushRoute(.show(feedURL: result.feedURL)) }
            ) {
                PodcastSubscribeBadge(feedURL: result.feedURL)
            }
        }
        .frame(width: width)   // nil = slot-driven (containerRelativeFrame at the row)
        .contextMenu {
            Button {
                UIPasteboard.general.string = result.feedURL
            } label: { Label("Copy Feed URL", systemImage: "doc.on.doc") }
        }
    }
}
