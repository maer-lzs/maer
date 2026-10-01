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
            let gesture = podcastMarkGesture(item)
            Button {
                podcastSetPlayed(item, gesture.marksPlayed)
            } label: {
                Label(gesture.marksPlayed ? String(localized: "Mark as Played") : String(localized: "Mark as Unplayed"),
                      systemImage: gesture.marksPlayed ? "checkmark.circle" : "arrow.uturn.backward.circle")
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

/// Per-show auto-download: for enabled shows, holds a chosen number of
/// episodes downloaded, read in the show's direction (cross-source RSS +
/// ABS). "Newest" only takes episodes that appeared since enabling, so old
/// episodes deleted by the user are not re-downloaded endlessly.
///
/// Three values, each per show and for all shows: on or off and the count
/// stay on this device (downloads are the device's), the direction travels
/// (it is how the person listens). A show without its own value follows the
/// one for all shows.
@MainActor
enum PodcastAutoDownload {
    typealias Direction = PodcastAutoDownloadRules.Direction

    static func flagKey(_ showId: String) -> String { "podcastAutoDownload.\(showId)" }
    private static func sinceKey(_ showId: String) -> String { "podcastAutoDownloadSince.\(showId)" }
    static func directionKey(_ showId: String) -> String { AppStorageKeys.podcastAutoDownloadDirection(showId) }
    static func keepKey(_ showId: String) -> String { "podcastAutoDownloadKeep.\(showId)" }
    static let generalOnKey = "podcastAutoDownloadOnAll"
    static let generalDirectionKey = "podcastAutoDownloadDirectionAll"
    static let generalKeepKey = "podcastAutoDownloadKeepAll"
    private static let generalSinceKey = "podcastAutoDownloadSinceAll"

    /// The one value the builds before carried, off, newest or in order, per
    /// show and for all shows. Never written again: it is split when read,
    /// off into off, the other two into on and that direction, and a value
    /// of the new keys wins over it. So an update moves nothing and writes
    /// nothing that could travel.
    private static func legacyKey(_ showId: String) -> String { "podcastAutoDownloadMode.\(showId)" }
    private static let generalLegacyKey = "podcastAutoDownloadModeAll"

    private static func legacyDirection(_ raw: String?) -> Direction? {
        raw.flatMap(Direction.init(rawValue:))
    }

    // MARK: On or off, on this device

    static func isEnabled(_ showId: String, defaults: UserDefaults = .standard) -> Bool {
        storedEnabled(showId, defaults: defaults) ?? generalEnabled(defaults: defaults)
    }

    /// The show's own switch, nil when it follows the one for all shows.
    /// Every build that wrote a direction wrote this switch beside it.
    static func storedEnabled(_ showId: String, defaults: UserDefaults = .standard) -> Bool? {
        defaults.object(forKey: flagKey(showId)) as? Bool
    }

    static func generalEnabled(defaults: UserDefaults = .standard) -> Bool {
        if let on = defaults.object(forKey: generalOnKey) as? Bool { return on }
        return legacyDirection(defaults.string(forKey: generalLegacyKey)) != nil
    }

    /// Switching on takes the cutoff of "newest" now, so the show fetches
    /// what appears from here on, not its whole backlog at once.
    static func setEnabled(_ showId: String, _ on: Bool) {
        let was = isEnabled(showId)
        AppStorageKeys.set(on, for: flagKey(showId))
        if on && !was { AppStorageKeys.set(Date().timeIntervalSince1970, for: sinceKey(showId)) }
    }

    static func setGeneralEnabled(_ on: Bool) {
        guard on != generalEnabled() else { return }
        AppStorageKeys.set(on, for: generalOnKey)
        if on { AppStorageKeys.set(Date().timeIntervalSince1970, for: generalSinceKey) }
    }

    static func clearEnabled(_ showId: String) {
        AppStorageKeys.remove(flagKey(showId))
        AppStorageKeys.remove(sinceKey(showId))
    }

    // MARK: The direction, which travels

    static func direction(_ showId: String, defaults: UserDefaults = .standard) -> Direction {
        storedDirection(showId, defaults: defaults) ?? generalDirection(defaults: defaults)
    }

    static func storedDirection(_ showId: String, defaults: UserDefaults = .standard) -> Direction? {
        legacyDirection(defaults.string(forKey: directionKey(showId)))
            ?? legacyDirection(defaults.string(forKey: legacyKey(showId)))
    }

    static func generalDirection(defaults: UserDefaults = .standard) -> Direction {
        legacyDirection(defaults.string(forKey: generalDirectionKey))
            ?? legacyDirection(defaults.string(forKey: generalLegacyKey))
            ?? .newest
    }

    /// A direction the person chose: stored, and said to the other devices.
    /// The field in front of it writes only a value the show does not act on
    /// already.
    static func setDirection(_ showId: String, _ direction: Direction) {
        AppStorageKeys.set(direction.rawValue, for: directionKey(showId))
        AppStorageKeys.noteChoice(direction.rawValue, key: directionKey(showId))
    }

    static func setGeneralDirection(_ direction: Direction) {
        guard direction != generalDirection() else { return }
        AppStorageKeys.set(direction.rawValue, for: generalDirectionKey)
        AppStorageKeys.noteChoice(direction.rawValue, key: generalDirectionKey)
    }

    /// The show follows the direction for all shows again, here and on the
    /// other devices. The old value goes with it, or it would still speak.
    static func clearDirection(_ showId: String) {
        AppStorageKeys.remove(legacyKey(showId))
        guard AppStorageKeys.string(directionKey(showId)) != nil else { return }
        AppStorageKeys.remove(directionKey(showId))
        AppStorageKeys.noteChoice(nil, key: directionKey(showId))
    }

    // MARK: The count, on this device

    static func keep(_ showId: String, defaults: UserDefaults = .standard) -> Int {
        storedKeep(showId, defaults: defaults) ?? generalKeep(defaults: defaults)
    }

    static func storedKeep(_ showId: String, defaults: UserDefaults = .standard) -> Int? {
        defaults.object(forKey: keepKey(showId)) as? Int
    }

    static func generalKeep(defaults: UserDefaults = .standard) -> Int {
        defaults.object(forKey: generalKeepKey) as? Int ?? PodcastAutoDownloadRules.keepByDefault
    }

    static func setKeep(_ showId: String, _ count: Int) {
        AppStorageKeys.set(count, for: keepKey(showId))
    }

    static func setGeneralKeep(_ count: Int) {
        guard count != generalKeep() else { return }
        AppStorageKeys.set(count, for: generalKeepKey)
    }

    static func clearKeep(_ showId: String) {
        AppStorageKeys.remove(keepKey(showId))
    }

    /// The cutoff of "newest" a run reads: the show's own, or for a show
    /// that follows, the moment the automatism was switched on for all.
    static func since(_ showId: String) -> Double {
        storedEnabled(showId) != nil
            ? AppStorageKeys.double(sinceKey(showId)) ?? 0
            : AppStorageKeys.double(generalSinceKey) ?? 0
    }

    /// The automatism's state for one show on THIS device, as one line of
    /// the show's copyable report: on or off, the direction and where it came
    /// from (a choice, the value of an older build, or all shows), the count,
    /// and the cutoff of "newest". A diagnosis line, not a sentence for the page.
    static func stateLine(_ showId: String, format: (Double) -> String) -> String {
        let on = isEnabled(showId) ? "on" : "off"
        let onOrigin = storedEnabled(showId) != nil ? "chosen" : "for all shows"
        let directionOrigin = AppStorageKeys.string(directionKey(showId)) != nil ? "chosen"
            : storedDirection(showId) != nil ? "from the older setting" : "for all shows"
        let cutoff = since(showId)
        let cutoffText = cutoff > 0 ? format(cutoff) : "-"
        return "Auto download on this device: \(on) (\(onOrigin)), direction \(direction(showId).rawValue) (\(directionOrigin)), keep \(keep(showId)), newest since \(cutoffText)"
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

    /// For all enabled shows, hold the chosen number of episodes downloaded,
    /// read in the show's direction (`PodcastAutoDownloadRules.hold`).
    ///
    /// Wi-Fi is a GATE for fetching, not a warning: this runs in the
    /// background, nobody is watching, and it is the only part of the app
    /// that can spend the user's data plan without them touching anything.
    /// Deleting spends nothing, so the own downloads over the count go
    /// without Wi-Fi too.
    ///
    /// The source of each episode is asked of `router`, so a witness can
    /// answer it without the session.
    static func run(shows: [PodcastShow], router: ItemRouter = .live) async {
        let onWiFi = await NetworkStatus.isOnWiFi()
        if !onWiFi {
            Logger.library.notice("AUTODOWNLOAD no Wi-Fi: tidying only, nothing fetched (cellular is never used unattended)")
        }
        let dm = DownloadManager.shared
        // One grip for every question of the same store.
        let progress = PodcastProgressStore.shared
        let owned = ownedByAutomation
        // The automatism does not know the player; the episode the player
        // holds is the standby pointer, and it counts as playing.
        let standby = AppStorageKeys.string(AppStorageKeys.lastPlayedItemId)
        for show in shows where isEnabled(show.id) {
            let entries = show.episodes.map { (item: podcastLibraryItem(show: show, episode: $0), episode: $0) }
            let byId = Dictionary(entries.map { ($0.item.id, $0) }) { first, _ in first }
            let byGuid = Dictionary(show.episodes.map { ($0.guid, $0) }) { first, _ in first }
            let isPlayed: (PodcastEpisode) -> Bool = {
                progress.state(guid: $0.guid, duration: $0.duration) == .played
            }
            let isBegun: (PodcastEpisode) -> Bool = {
                if case .inProgress = progress.state(guid: $0.guid, duration: $0.duration) { return true }
                return false
            }
            // The DIRECTION is the show's choice. "Newest": the unheard
            // episodes since the cutoff, newest first. "In order": from where
            // the listener stands, the unheard ones ascending.
            let direction = direction(show.id)
            let wanted: [String]
            switch direction {
            case .newest:
                let cutoff = since(show.id)
                wanted = entries
                    .filter { $0.episode.pubDate >= cutoff && !isPlayed($0.episode) }
                    .sorted { $0.episode.pubDate > $1.episode.pubDate }
                    .map(\.item.id)
            case .inOrder:
                let picked = PodcastAutoDownloadRules.nextInOrder(
                    show.episodes.map { .init(guid: $0.guid, pubDate: $0.pubDate) },
                    isPlayed: { guid in byGuid[guid].map(isPlayed) ?? false },
                    isStarted: { guid in
                        guard let episode = byGuid[guid],
                              case .inProgress(_, let remaining) = progress.state(guid: guid, duration: episode.duration)
                        else { return false }
                        return episode.duration - remaining >= PodcastAutoDownloadRules.startedAtLeast
                    },
                    isDownloaded: { _ in false },
                    limit: .max)
                wanted = picked.compactMap { guid in byGuid[guid].map { podcastLibraryItem(show: show, episode: $0).id } }
            }
            let own = entries
                .filter { owned.contains($0.item.id) && dm.isDownloaded(itemId: $0.item.id) }
                .map { PodcastAutoDownloadRules.Owned(id: $0.item.id, pubDate: $0.episode.pubDate,
                                                      isProtected: isBegun($0.episode) || $0.item.id == standby) }
            let keep = keep(show.id)
            let plan = PodcastAutoDownloadRules.hold(wanted: wanted, isDownloaded: { dm.isDownloaded(itemId: $0) },
                                                     own: own, direction: direction, limit: keep)
            for id in plan.drop { dm.deleteDownload(itemId: id) }
            // One line per show and run: which direction ran with which
            // count, from which cutoff, what it held, fetched and let go, and
            // the dates of what it fetched. Without it a device report
            // ("in order" chosen, the newest loaded) cannot tell which
            // direction the run had read.
            let fetchDates = plan.fetch.compactMap { byId[$0]?.episode.pubDate }
            Logger.library.notice("AUTODOWNLOAD show=\(show.id, privacy: .public) direction=\(direction.rawValue, privacy: .public) keep=\(keep) since=\(Int(since(show.id))) own=\(own.count) fetch=\(onWiFi ? plan.fetch.count : 0) drop=\(plan.drop.count) oldest=\(Int(fetchDates.min() ?? 0)) newest=\(Int(fetchDates.max() ?? 0))")
            guard onWiFi else { continue }
            var failure: String?
            for item in plan.fetch.compactMap({ byId[$0]?.item }) where !dm.isDownloaded(itemId: item.id) {
                let provider = router.provider(item.id)
                do {
                    let detail = try await provider.fetchItemDetail(itemId: item.id)
                    await dm.download(item: detail, provider: provider, kind: .podcasts)
                    ownedByAutomation.insert(item.id)
                } catch {
                    // An episode that cannot be fetched used to fall
                    // out of the run silently. It says so now, and says why.
                    let title = item.media?.metadata?.title ?? item.id
                    failure = String(localized: "\(title) could not be downloaded: \(ErrorSentence.of(error))")
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
            let finished = stored.map {
                ProgressMark.isPlayed(stored: $0, currentDuration: duration, tail: PlayedTail.seconds(forItemId: id))
            } ?? false
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

/// "2 days ago", or "today 09:05" for an episode published ahead of time.
/// From `addedAt` (pubDate), through the one rule `EpisodeDateLine`.
func relativeDateText(_ item: LibraryItem) -> String {
    EpisodeDateLine.text(ms: item.addedAt)
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
