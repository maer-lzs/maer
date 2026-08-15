// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import SwiftUI
import Combine
import UIKit
import OSLog

/// Fully unsubscribe from a feed — from BOTH sources by the normalised feed URL:
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
    /// Unified episode context menu (Force Touch / long-press) — the same
    /// everywhere: play, into the queue, played/unplayed, download/delete.
    @ViewBuilder
    /// df0b3bb 3: `showsContinueHide` is set by the CONTINUE row only — on an
    /// ordinary episode row the entry would have nothing to act on.
    func podcastEpisodeMenu(item: LibraryItem, playerCoordinator: PlayerCoordinator,
                            showsContinueHide: Bool = false) -> some View {
        contextMenu {
            if showsContinueHide {
                Button {
                    // Same local stamp the Continue rows sort by (the last
                    // saved position), so hide/return use ONE clock.
                    let stamp = ProgressMark.timestamp(UserDefaults.standard.array(forKey: AppStorageKeys.localPosition(item.id)) as? [Double]) ?? 0
                    ContinueHiddenStore.hide(id: item.id, lastUpdate: stamp)
                } label: {
                    Label("Don't show under Continue", systemImage: "eye.slash")
                }
                Divider()
            }
            // Offline, an episode without a download cannot start — hide the
            // play entries entirely instead of leaving them visible but dead.
            // R1: text-only episodes (no enclosure) NEVER get play/queue/
            // download/played entries — the menu only offers the notes tap.
            let isTextOnly = !PodcastSubscriptions.shared.isPlayableEpisode(itemId: item.id)
            let isPlayable = !isTextOnly && (NetworkMonitor.shared.isConnected
                || DownloadManager.shared.isDownloaded(itemId: item.id))
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
                MaerPlaylistMenu(itemId: item.id)
            }
            if !isTextOnly {
            let played = podcastPlayState(for: item) == .played
            Button {
                podcastSetPlayed(item, !played)
            } label: {
                Label(played ? String(localized: "Mark as Unplayed") : String(localized: "Mark as Played"),
                      systemImage: played ? "arrow.uturn.backward.circle" : "checkmark.circle")
            }
            if DownloadManager.shared.isDownloaded(itemId: item.id) {
                Button(role: .destructive) {
                    DownloadManager.shared.deleteDownload(itemId: item.id)
                } label: { Label("Delete Download", systemImage: "trash") }
            } else if NetworkMonitor.shared.isConnected {
                // A7: offline a download can't start — hide the entry.
                Button {
                    Task {
                        let p = AppSession.shared.provider(for: item.id)
                        if let d = try? await p.fetchItemDetail(itemId: item.id) {
                            await DownloadManager.shared.download(item: d, provider: p)
                        }
                    }
                } label: { Label("Download", systemImage: "arrow.down.circle") }
            }
            }
        }
    }

    /// Unified show context menu (subscribed): mark all played, unsubscribe.
    @ViewBuilder
    func podcastShowMenu(_ show: PodcastShow) -> some View {
        contextMenu {
            Button {
                for ep in show.episodes {
                    podcastSetPlayed(podcastLibraryItem(show: show, episode: ep), true)
                }
            } label: { Label("Mark All as Played", systemImage: "checkmark.circle") }
            // 92e25d6: the manual premium marking right at the show — the
            // escape hatch for unknown URL patterns, same truth as the
            // management section.
            if PodcastSubscriptions.isManuallyMarkedPremium(show.feedURL) {
                Button {
                    PodcastSubscriptions.setManualPremium(false, feedURL: show.feedURL)
                    PodcastSubscriptions.shared.objectWillChange.send()
                } label: { Label("Remove premium marking", systemImage: "lock.slash") }
            } else if !PodcastSubscriptions.isPremiumFeed(show.feedURL) {
                Button {
                    PodcastSubscriptions.setManualPremium(true, feedURL: show.feedURL)
                    PodcastSubscriptions.shared.objectWillChange.send()
                } label: { Label("Mark as Premium", systemImage: "lock") }
            }
            Button(role: .destructive) {
                podcastUnsubscribe(show)
            } label: { Label("Unsubscribe", systemImage: "minus.circle") }
        }
    }
}

/// PodcastShow + episode → LibraryItem (source-agnostic). The namespace in the
/// `guid`/`id` (`rss:`/`abspod:`) routes playback/cover/progress to the right
/// source. `nonisolated`: pure mapping, used from the off-main podcast-sections
/// compute.
nonisolated func podcastLibraryItem(show: PodcastShow, episode: PodcastEpisode) -> LibraryItem {
    LibraryItem(
        id: episode.guid,
        media: LibraryItemMedia(
            metadata: LibraryItemMetadata(
                title: episode.title, authorName: show.title, narratorName: nil,
                seriesName: show.title, genres: nil, publishedYear: nil,
                description: episode.description
            ),
            duration: episode.duration, chapters: nil,
            tracks: [ABSAudioTrack(index: 0, startOffset: nil, duration: episode.duration,
                                   contentUrl: episode.audioURL, metadata: nil)]
        ),
        addedAt: episode.pubDate
    )
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

    /// What the automatism fetches — a CHOICE per show, not one direction for
    /// everyone: a news show wants the newest, a backlog wants the beginning.
    /// Replacing the direction outright would have handed the news normal
    /// case the OLDEST episodes.
    enum Mode: String, CaseIterable {
        case off
        /// The prior behaviour, and the migration target for every show that
        /// had the old toggle ON: the newest N since enabling.
        case newest
        /// The first N unheard, ascending — listening through from the start.
        case inOrder
    }

    static func mode(_ showId: String) -> Mode {
        if let raw = UserDefaults.standard.string(forKey: modeKey(showId)),
           let stored = Mode(rawValue: raw) {
            return stored
        }
        // Migration from the old toggle: ON meant "newest since enabling" —
        // that meaning is preserved, nobody's news show flips to the archive.
        return UserDefaults.standard.bool(forKey: flagKey(showId)) ? .newest : .off
    }

    static func setMode(_ showId: String, _ mode: Mode) {
        UserDefaults.standard.set(mode.rawValue, forKey: modeKey(showId))
        // The old flag mirrors on/off so every existing reader keeps working.
        UserDefaults.standard.set(mode != .off, forKey: flagKey(showId))
        if mode == .newest {
            UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: sinceKey(showId))
        }
    }

    static func isEnabled(_ showId: String) -> Bool {
        mode(showId) != .off
    }

    static func setEnabled(_ showId: String, _ on: Bool) {
        setMode(showId, on ? .newest : .off)
    }

    /// What the automatism itself downloaded — the cleanup below touches
    /// nothing else. A property of the data, not a guess from a file's age.
    private static let ownedKey = "podcastAutoDownloadedIds"
    static var ownedByAutomation: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: ownedKey) ?? []) }
        set { UserDefaults.standard.set(Array(newValue), forKey: ownedKey) }
    }

    /// Why the last run could not fetch an episode of this show. Shown in the
    /// show's settings next to the switch — a background job that fails must
    /// be findable where it was switched on.
    static func errorKey(_ showId: String) -> String { "podcastAutoDownloadError.\(showId)" }
    static func lastError(_ showId: String) -> String? {
        UserDefaults.standard.string(forKey: errorKey(showId))
    }

    /// For all enabled shows, pull the new (since the cutoff), not-yet-local
    /// episodes. `perShow` caps it per run.
    ///
    /// Wi-Fi is a GATE, not a warning: this runs in the background, nobody is
    /// watching, and it is the only part of the app that can spend the user's
    /// data plan without them touching anything.
    static func run(shows: [PodcastShow], perShow: Int = 3) async {
        guard await NetworkStatus.isOnWiFi() else {
            Logger.library.notice("AUTODOWNLOAD skipped — no Wi-Fi (cellular is never used unattended)")
            return
        }
        let dm = DownloadManager.shared
        for show in shows where isEnabled(show.id) {
            // The DIRECTION is the show's choice. "Newest" keeps the prior
            // behaviour (since-cutoff, newest first); "in order" fetches the
            // first N unheard ascending — where a backlog listener actually
            // is. Played and already-local episodes fall out before the cap.
            let candidates: [LibraryItem]
            switch mode(show.id) {
            case .off:
                continue
            case .newest:
                let since = UserDefaults.standard.double(forKey: sinceKey(show.id))
                candidates = show.episodes
                    .filter { $0.pubDate >= since }
                    .sorted { $0.pubDate > $1.pubDate }
                    .prefix(perShow)
                    .map { podcastLibraryItem(show: show, episode: $0) }
            case .inOrder:
                let byGuid = Dictionary(show.episodes.map { ($0.guid, $0) }) { first, _ in first }
                let picked = PodcastAutoDownloadRules.nextInOrder(
                    show.episodes.map { .init(guid: $0.guid, pubDate: $0.pubDate) },
                    isPlayed: { guid in
                        guard let episode = byGuid[guid] else { return false }
                        return PodcastProgressStore.shared.state(
                            guid: guid, duration: episode.duration) == .played
                    },
                    isDownloaded: { dm.isDownloaded(itemId: $0) },
                    limit: perShow)
                candidates = picked.compactMap { guid in
                    byGuid[guid].map { podcastLibraryItem(show: show, episode: $0) }
                }
            }
            var failure: String?
            for item in candidates where !dm.isDownloaded(itemId: item.id) {
                let provider = AppSession.shared.provider(for: item.id)
                do {
                    let detail = try await provider.fetchItemDetail(itemId: item.id)
                    await dm.download(item: detail, provider: provider)
                    ownedByAutomation.insert(item.id)
                } catch {
                    // Regel 3: an episode that cannot be fetched used to fall
                    // out of the run silently. It says so now, and says why.
                    let title = item.media?.metadata?.title ?? item.id
                    failure = String(localized: "\(title) could not be downloaded: \(error.localizedDescription)")
                    Logger.library.error("AUTODOWNLOAD failed for \(item.id, privacy: .public): \(String(describing: error), privacy: .public)")
                }
            }
            if let failure {
                UserDefaults.standard.set(failure, forKey: errorKey(show.id))
            } else {
                UserDefaults.standard.removeObject(forKey: errorKey(show.id))
            }
        }
        sweep()
    }

    /// Delete finished automatic downloads after the keep window — and only
    /// those. Anything downloaded by hand is untouched, whatever its age.
    static func sweep(now: Double = Date().timeIntervalSince1970) {
        let dm = DownloadManager.shared
        let owned = ownedByAutomation
        guard !owned.isEmpty else { return }
        let items: [PodcastAutoDownloadRules.Item] = owned.map { id in
            let stored = UserDefaults.standard.array(forKey: AppStorageKeys.localPosition(id)) as? [Double]
            let position = stored?.first ?? 0
            // The mark already carries the moment it was written (milliseconds)
            // — no second bookkeeping for "finished when".
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

/// "2 days ago" — relative date from `addedAt` (pubDate).
func relativeDateText(_ item: LibraryItem) -> String {
    guard let added = item.addedAt, added > 0 else { return "" }
    return Date(timeIntervalSince1970: added / 1000)
        .formatted(.relative(presentation: .named))
}

/// "55 min" or "1 h 51 min" from the episode duration.
func durationText(_ item: LibraryItem) -> String {
    // 33bf469 P1 (Fund gilt auch fuer uns): duration 0 is the ABSENCE
    // of a duration, not a length — livestream rips and YouTube-bridge feeds
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
/// forces a thumbnail of this target size (e.g. 800 px for the "Up Next" cards —
/// sharp, but far lighter than the full decode up to ~2200 px).
@ViewBuilder
func podcastArtwork(url: URL?, size: CGFloat, corner: CGFloat, thumbnailPixel: CGFloat? = nil) -> some View {
    let shape = RoundedRectangle(cornerRadius: corner, style: .continuous)
    Group {
        if let url {
            CachedAsyncImage(url: url,
                             useThumbnail: thumbnailPixel != nil || size <= 200,
                             thumbnailMaxPixel: thumbnailPixel) { image in
                image.resizable().aspectRatio(contentMode: .fill)
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
