// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import SwiftUI
import Combine
import UIKit
import OSLog

/// Fully unsubscribe from a feed. From BOTH sources by the normalised feed URL:
/// remove the RSS subscription (the gpodder reconcile then sends `remove`) AND
/// archive a same-named ABS show (server history stays). So the feed does not
/// come back as "another source".
@MainActor
func podcastUnsubscribe(_ show: PodcastShow) {
    let norm = PodcastSubscriptions.normalizeFeedURL(show.feedURL)
    for s in PodcastSubscriptions.shared.shows
        where PodcastSubscriptions.normalizeFeedURL(s.feedURL) == norm {
        PodcastSubscriptions.shared.unsubscribe(id: s.id)
    }
    for s in ABSPodcastProvider.shared.shows
        where PodcastSubscriptions.normalizeFeedURL(s.feedURL) == norm {
        ABSPodcastProvider.shared.setArchived(s.id, true)
    }
    Task { await GPodderSync.shared.reconcile() }
}

extension View {
    /// Unified episode context menu (Force Touch / long-press). The same
    /// everywhere: play, into the queue, played/unplayed, download/delete.
    @ViewBuilder
    /// `showsContinueHide` is set by the CONTINUE row only. On an
    /// ordinary episode row the entry would have nothing to act on.
    /// `router` answers the source of the episode: an extension has no
    /// environment of its own, so it is handed in, the live one by default.
    func podcastEpisodeMenu(item: LibraryItem, playerCoordinator: PlayerCoordinator,
                            showsContinueHide: Bool = false,
                            coListened: CoListened.Show? = nil,
                            router: ItemRouter = .live) -> some View {
        contextMenu {
            // A co-listened show (heard, never subscribed): the one grip to
            // subscribe, and the user's way out of the row.
            if let coListened {
                Button {
                    Task {
                        await PodcastSubscribeBadge.subscribe(coListened.feedURL)
                        NotificationCenter.default.post(name: .coListenedChanged, object: nil)
                    }
                } label: {
                    Label("Subscribe", systemImage: "plus.circle")
                }
                Button {
                    CoListenedShows.hide(feedKey: coListened.feedKey)
                } label: {
                    Label("Don't show this show", systemImage: "eye.slash")
                }
                Divider()
            }
            if showsContinueHide {
                Button {
                    // Same local stamp the Continue rows sort by (the last
                    // saved position), so hide/return use ONE clock.
                    let stamp = ProgressMark.timestamp(ListeningStore.backup(item.id)) ?? 0
                    ContinueHiddenStore.hide(id: item.id, lastUpdate: stamp)
                } label: {
                    Label("Don't show under Continue", systemImage: "eye.slash")
                }
                Divider()
            }
            // Offline, an episode without a download cannot start. Hide the
            // play entries entirely instead of leaving them visible but dead.
            // Text-only episodes (no enclosure) NEVER get play/queue/
            // download/played entries. The menu only offers the notes tap.
            let isTextOnly = !PodcastSubscriptions.shared.isPlayableEpisode(itemId: item.id)
            let isPlayable = !isTextOnly && MediaAvailability.canPlayNow(
                isConnected: NetworkMonitor.shared.isConnected,
                isDownloaded: DownloadManager.shared.isDownloaded(itemId: item.id))
            if isPlayable {
                Button {
                    Task { await playerCoordinator.open(item: item) }
                } label: { Label("Play", systemImage: "play.fill") }
                Button {
                    PlayQueue.shared.playNext(item.id)
                } label: { Label("Play Next", systemImage: "text.insert") }
                Button {
                    PlayQueue.shared.playLast(item.id)
                } label: { Label("Play Last", systemImage: "text.append") }
                AddToPlaylistButton(itemId: item.id,
                                    knownTitles: [item.id: item.title])
            }
            if !isTextOnly {
            let played = podcastPlayState(for: item) == .played
            Button {
                podcastSetPlayed(item, !played)
            } label: {
                Label(played ? String(localized: "Mark as Unplayed") : String(localized: "Mark as Played"),
                      systemImage: played ? "arrow.uturn.backward.circle" : "checkmark.circle")
            }
            if DownloadManager.shared.isDeletableDownload(itemId: item.id) {
                Button(role: .destructive) {
                    DownloadManager.shared.deleteDownload(itemId: item.id)
                } label: { Label("Delete Download", systemImage: "trash") }
            } else if NetworkMonitor.shared.isConnected,
                      MediaDownloadOffer.isPossible(router.provider(item.id).capabilities) {
                // Offline a download can't start. Hide the entry.
                Button {
                    Task { await DownloadManager.shared.startDownload(itemId: item.id, kind: .podcasts) }
                } label: { Label("Download", systemImage: "arrow.down.circle") }
            }
            }
        }
    }

    /// Unified show context menu (subscribed): mark all played, unsubscribe.
    @ViewBuilder
    func podcastShowMenu(_ show: PodcastShow) -> some View {
        contextMenu {
            PodcastShowMenuItems(show: show)
        }
    }
}

/// The entries of the show context menu. The premium marking is read from
/// stored choices, and the store announces a change of it on its own
/// publisher, so the entries observe the store themselves: no page that shows
/// a show tile has to observe for the menu to offer the right marking.
private struct PodcastShowMenuItems: View {
    @ObservedObject private var subs = PodcastSubscriptions.shared
    let show: PodcastShow

    var body: some View {
        Button {
            for ep in show.episodes {
                podcastSetPlayed(podcastLibraryItem(show: show, episode: ep), true)
            }
        } label: { Label("Mark All as Played", systemImage: "checkmark.circle") }
        // The manual premium marking right at the show. The
        // escape hatch for unknown URL patterns, same truth as the
        // management section.
        if PodcastSubscriptions.isManuallyMarkedPremium(show.feedURL) {
            Button {
                PodcastSubscriptions.setManualPremium(false, feedURL: show.feedURL)
            } label: { Label("Remove premium marking", systemImage: "lock.slash") }
        } else if !PodcastSubscriptions.isPremiumFeed(show.feedURL) {
            Button {
                PodcastSubscriptions.setManualPremium(true, feedURL: show.feedURL)
            } label: { Label("Mark as Premium", systemImage: "lock") }
        }
        Button(role: .destructive) {
            podcastUnsubscribe(show)
        } label: { Label("Unsubscribe", systemImage: "minus.circle") }
    }
}

/// Per-show auto-download: for enabled shows, downloads the newest episodes that
/// appeared since enabling, locally (cross-source RSS + ABS). Only episodes
/// AFTER the enabling time are pulled so old episodes deleted by the user are not
/// re-downloaded endlessly.
@MainActor
enum PodcastAutoDownload {
    static func flagKey(_ showId: String) -> String { "podcastAutoDownload.\(showId)" }
    private static func sinceKey(_ showId: String) -> String { "podcastAutoDownloadSince.\(showId)" }

    private static func modeKey(_ showId: String) -> String { "podcastAutoDownloadMode.\(showId)" }

    /// What the automatism fetches. A CHOICE per show, not one direction for
    /// everyone: a news show wants the newest, a backlog wants the beginning.
    /// Replacing the direction outright would have handed the news normal
    /// case the OLDEST episodes.
    enum Mode: String, CaseIterable {
        case off
        /// The prior behaviour, and the migration target for every show that
        /// had the old toggle ON: the newest N since enabling.
        case newest
        /// The first N unheard, ascending. Listening through from the start.
        case inOrder
    }

    /// The direction for all shows, and the moment "newest" was
    /// chosen for them. It stays on this device, like each show's own.
    private static let generalModeKey = "podcastAutoDownloadModeAll"
    private static let generalSinceKey = "podcastAutoDownloadSinceAll"

    static func mode(_ showId: String) -> Mode {
        storedMode(showId) ?? generalMode
    }

    /// The show's own direction, nil when it follows the one for all shows.
    static func storedMode(_ showId: String) -> Mode? {
        if let raw = AppStorageKeys.string(modeKey(showId)),
           let stored = Mode(rawValue: raw) {
            return stored
        }
        // Migration from the old toggle: ON meant "newest since enabling".
        // That meaning is preserved, nobody's news show flips to the archive.
        return AppStorageKeys.bool(flagKey(showId)) ? .newest : nil
    }

    static var generalMode: Mode {
        AppStorageKeys.string(generalModeKey).flatMap(Mode.init(rawValue:)) ?? .off
    }

    /// "Newest" for all shows takes its cutoff now, so a show that follows
    /// fetches what appears from here on, not its newest three at once.
    static func setGeneralMode(_ mode: Mode) {
        guard mode != generalMode else { return }
        AppStorageKeys.set(mode.rawValue, for: generalModeKey)
        if mode == .newest {
            AppStorageKeys.set(Date().timeIntervalSince1970, for: generalSinceKey)
        }
    }

    /// The show follows the direction for all shows again.
    static func clearMode(_ showId: String) {
        AppStorageKeys.remove(modeKey(showId))
        AppStorageKeys.remove(flagKey(showId))
        AppStorageKeys.remove(sinceKey(showId))
    }

    /// The cutoff of "newest" a run reads: the show's own, or for a show
    /// that follows, the moment "newest" was chosen for all.
    static func since(_ showId: String) -> Double {
        storedMode(showId) != nil
            ? AppStorageKeys.double(sinceKey(showId)) ?? 0
            : AppStorageKeys.double(generalSinceKey) ?? 0
    }

    static func setMode(_ showId: String, _ mode: Mode) {
        AppStorageKeys.set(mode.rawValue, for: modeKey(showId))
        // The old flag mirrors on/off so every existing reader keeps working.
        AppStorageKeys.set(mode != .off, for: flagKey(showId))
        if mode == .newest {
            AppStorageKeys.set(Date().timeIntervalSince1970, for: sinceKey(showId))
        }
    }

    static func isEnabled(_ showId: String) -> Bool {
        mode(showId) != .off
    }

    /// The automatism's state for one show on THIS device, as one line of
    /// the show's copyable report: the direction it reads, where that came
    /// from (a stored choice, the migration of the old switch, or the
    /// direction for all shows), and the cutoff of "newest". A diagnosis
    /// line, not a sentence for the page.
    static func stateLine(_ showId: String, format: (Double) -> String) -> String {
        let origin = AppStorageKeys.string(modeKey(showId)) != nil ? "chosen"
            : storedMode(showId) != nil ? "from the old switch" : "for all shows"
        let cutoff = since(showId)
        let cutoffText = cutoff > 0 ? format(cutoff) : "-"
        return "Auto download on this device: \(mode(showId).rawValue) (\(origin)), newest since \(cutoffText)"
    }

    static func setEnabled(_ showId: String, _ on: Bool) {
        setMode(showId, on ? .newest : .off)
    }

    /// What the automatism itself downloaded. The cleanup below touches
    /// nothing else. A property of the data, not a guess from a file's age.
    private static let ownedKey = "podcastAutoDownloadedIds"
    static var ownedByAutomation: Set<String> {
        get { Set(AppStorageKeys.stringArray(ownedKey) ?? []) }
        set { AppStorageKeys.set(Array(newValue), for: ownedKey) }
    }

    /// Why the last run could not fetch an episode of this show. Shown in the
    /// show's settings next to the switch. A background job that fails must
    /// be findable where it was switched on.
    static func errorKey(_ showId: String) -> String { "podcastAutoDownloadError.\(showId)" }
    static func lastError(_ showId: String) -> String? {
        AppStorageKeys.string(errorKey(showId))
    }

    /// For all enabled shows, pull the new (since the cutoff), not-yet-local
    /// episodes. `perShow` caps it per run.
    ///
    /// Wi-Fi is a GATE, not a warning: this runs in the background, nobody is
    /// watching, and it is the only part of the app that can spend the user's
    /// data plan without them touching anything.
    ///
    /// The source of each episode is asked of `router`, so a witness can
    /// answer it without the session.
    static func run(shows: [PodcastShow], perShow: Int = 3, router: ItemRouter = .live) async {
        guard await NetworkStatus.isOnWiFi() else {
            Logger.library.notice("AUTODOWNLOAD skipped — no Wi-Fi (cellular is never used unattended)")
            return
        }
        let dm = DownloadManager.shared
        for show in shows where isEnabled(show.id) {
            // The DIRECTION is the show's choice. "Newest" keeps the prior
            // behaviour (since-cutoff, newest first); "in order" fetches the
            // first N unheard ascending. Where a backlog listener actually
            // is. Played and already-local episodes fall out before the cap.
            let candidates: [LibraryItem]
            switch mode(show.id) {
            case .off:
                continue
            case .newest:
                let cutoff = since(show.id)
                candidates = show.episodes
                    .filter { $0.pubDate >= cutoff }
                    .sorted { $0.pubDate > $1.pubDate }
                    .prefix(perShow)
                    .map { podcastLibraryItem(show: show, episode: $0) }
            case .inOrder:
                let byGuid = Dictionary(show.episodes.map { ($0.guid, $0) }) { first, _ in first }
                // One grip for both questions of the same store.
                let progress = PodcastProgressStore.shared
                let picked = PodcastAutoDownloadRules.nextInOrder(
                    show.episodes.map { .init(guid: $0.guid, pubDate: $0.pubDate) },
                    isPlayed: { guid in
                        guard let episode = byGuid[guid] else { return false }
                        return progress.state(guid: guid, duration: episode.duration) == .played
                    },
                    isStarted: { guid in
                        guard let episode = byGuid[guid],
                              case .inProgress(_, let remaining) = progress.state(guid: guid, duration: episode.duration)
                        else { return false }
                        return episode.duration - remaining >= PodcastAutoDownloadRules.startedAtLeast
                    },
                    isDownloaded: { dm.isDownloaded(itemId: $0) },
                    limit: perShow)
                candidates = picked.compactMap { guid in
                    byGuid[guid].map { podcastLibraryItem(show: show, episode: $0) }
                }
            }
            // One line per show and run: which direction ran, from which
            // cutoff, and which episodes it chose by date. GT-14 could not be
            // told from the device: "in order" chosen, the newest loaded, and
            // no line said which mode the run had read.
            let pickedDates = candidates.compactMap { item in
                show.episodes.first { podcastLibraryItem(show: show, episode: $0).id == item.id }?.pubDate
            }
            Logger.library.notice("AUTODOWNLOAD show=\(show.id, privacy: .public) mode=\(mode(show.id).rawValue, privacy: .public) since=\(Int(since(show.id))) picked=\(candidates.count) oldest=\(Int(pickedDates.min() ?? 0)) newest=\(Int(pickedDates.max() ?? 0))")
            var failure: String?
            for item in candidates where !dm.isDownloaded(itemId: item.id) {
                let provider = router.provider(item.id)
                do {
                    let detail = try await provider.fetchItemDetail(itemId: item.id)
                    await dm.download(item: detail, provider: provider, kind: .podcasts)
                    ownedByAutomation.insert(item.id)
                } catch {
                    // An episode that cannot be fetched used to fall
                    // out of the run silently. It says so now, and says why.
                    let title = item.media?.metadata?.title ?? item.id
                    failure = String(localized: "\(title) could not be downloaded: \(error.localizedDescription)")
                    Logger.library.error("AUTODOWNLOAD failed for \(item.id, privacy: .public): \(String(describing: error), privacy: .public)")
                }
            }
            AppStorageKeys.set(failure, for: errorKey(show.id))
        }
        sweep()
    }

    /// Delete finished automatic downloads after the keep window. And only
    /// those. Anything downloaded by hand is untouched, whatever its age.
    static func sweep(now: Double = Date().timeIntervalSince1970) {
        let dm = DownloadManager.shared
        let owned = ownedByAutomation
        guard !owned.isEmpty else { return }
        let items: [PodcastAutoDownloadRules.Item] = owned.map { id in
            let stored = ListeningStore.backup(id)
            let position = stored?.first ?? 0
            // The mark already carries the moment it was written (milliseconds).
            // No second bookkeeping for "finished when".
            let finishedAt = (ProgressMark.timestamp(stored) ?? 0) / 1000
            let duration = dm.loadCachedDetail(forItemId: id)?.media.duration ?? 0
            let finished = stored.map { ProgressMark.isPlayed(stored: $0, currentDuration: duration) } ?? false
            _ = position
            return .init(id: id, isFinished: finished, finishedAt: finishedAt)
        }
        let expired = PodcastAutoDownloadRules.expired(items, ownedByAutomation: owned, now: now)
        for id in expired { dm.deleteDownload(itemId: id) }
        if !expired.isEmpty {
            Logger.library.notice("AUTODOWNLOAD swept \(expired.count) finished downloads (kept manual ones)")
        }
        let stillThere = Set(owned.filter { dm.isDownloaded(itemId: $0) })
        ownedByAutomation = PodcastAutoDownloadRules.forget(
            ownedByAutomation: owned, deleted: expired, stillDownloaded: stillThere)
    }
}

/// Feed-only episode of an ABS show → playable `rss:` item: streams from the
/// original host, progress runs local+iCloud (no server download needed). Same
/// `rss:<feedKey>:<guid>` id as RSS/PodcastIndex → shared progress, and the
/// basis for the later server handoff.
@MainActor
func feedEpisodePlayItem(show: PodcastShow, feed: FeedEpisode) -> LibraryItem {
    let guid = "rss:\(PodcastSubscriptions.feedKey(show.feedURL)):\(feed.id)"
    return LibraryItem(
        id: guid,
        media: LibraryItemMedia(
            metadata: LibraryItemMetadata(
                title: feed.title, authorName: show.title, narratorName: nil,
                seriesName: show.title, genres: nil, publishedYear: nil, description: nil),
            duration: feed.duration, chapters: nil,
            tracks: [ABSAudioTrack(index: 0, startOffset: nil, duration: feed.duration,
                                   contentUrl: feed.enclosureUrl, metadata: nil)]),
        addedAt: feed.publishedAt)
}

// MARK: - Source-aware played state

/// Reduce HTML from episode descriptions to plain text (tags/entities),
/// analogous to `BookDetailScreen.plainText(fromHTML:)`.
func podcastPlainText(_ html: String) -> String {
    var text = html
    text = text.replacingOccurrences(of: "</p>", with: "\n\n", options: .caseInsensitive)
    text = text.replacingOccurrences(of: "<br\\s*/?>", with: "\n", options: [.caseInsensitive, .regularExpression])
    text = text.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
    let entities = ["&amp;": "&", "&nbsp;": " ", "&quot;": "\"", "&#39;": "'", "&apos;": "'", "&lt;": "<", "&gt;": ">"]
    for (entity, replacement) in entities {
        text = text.replacingOccurrences(of: entity, with: replacement)
    }
    return text.trimmingCharacters(in: .whitespacesAndNewlines)
}

/// "2 days ago". Relative date from `addedAt` (pubDate).
func relativeDateText(_ item: LibraryItem) -> String {
    guard let added = item.addedAt, added > 0 else { return "" }
    return Date(timeIntervalSince1970: added / 1000)
        .formatted(.relative(presentation: .named))
}

/// "55 min" or "1 h 51 min" from the episode duration.
func durationText(_ item: LibraryItem) -> String {
    // Duration 0 is the ABSENCE
    // of a duration, not a length. Livestream rips and YouTube-bridge feeds
    // carry it often. "0 min" claimed a length nobody measured; the line
    // stays empty instead (the played/progress paths were already guarded).
    let seconds = item.media?.duration ?? 0
    guard seconds > 0 else { return "" }
    let total = Int(seconds / 60)
    if total >= 60 {
        return String(localized: "\(total / 60) h \(total % 60) min")
    }
    return String(localized: "\(total) min")
}

/// Podcast cover (remote URL) with a fallback microphone. `thumbnailPixel`
/// forces a thumbnail of this target size (e.g. 800 px for the "Up Next" cards.
/// Sharp, but far lighter than the full decode up to ~2200 px).
@ViewBuilder
func podcastArtwork(url: URL?, size: CGFloat, corner: CGFloat, thumbnailPixel: CGFloat? = nil) -> some View {
    let shape = RoundedRectangle(cornerRadius: corner, style: .continuous)
    Group {
        if let url {
            CachedAsyncImage(url: url,
                             useThumbnail: thumbnailPixel != nil || size <= 200,
                             thumbnailMaxPixel: thumbnailPixel) { image, pixels in
                // THE podcast cover renderer: the continue card, the
                // episode page and the show header all come through here.
                // A card-sized face is alone on screen and gets the
                // blurred backdrop; a small one sits in a scrolling row.
                CoverFitting(image: image, pixelSize: pixels,
                             backdrop: size > 200 ? .blurredSelf : .neutral)
            } placeholder: {
                shape.fill(Color.secondary.opacity(0.15))
            }
        } else {
            shape.fill(Color.secondary.opacity(0.15))
                .overlay(Image(systemName: "mic").font(.title3).foregroundStyle(.secondary))
        }
    }
    .frame(width: size, height: size)
    .clipShape(shape)
}
