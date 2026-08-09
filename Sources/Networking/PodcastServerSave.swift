// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation

/// "Download-on-play": when a feed-only episode of an ABS show is played
/// (streams from the original host as an `rss:` item), the server saves it after
/// ~30 s of listening — so it gains server-side progress (multi-client/web UI)
/// while playback started immediately. The local/iCloud progress is then
/// re-keyed onto the new server episode (handoff).
///
/// Best effort: if the handoff fails (no match/no permission), the episode is
/// still on the server and progress stays in sync across your own devices via
/// iCloud.
@MainActor
final class PodcastServerSave {
    static let shared = PodcastServerSave()
    private init() {}

    /// Like the toggle in the settings (`@AppStorage("podcastAutoSaveOnPlay")`),
    /// here directly from UserDefaults — default on.
    private var autoSave: Bool {
        AppStorageKeys.podcastAutoSaveOnPlayValue
    }

    private struct Pending { let showId: String; let feed: FeedEpisode }
    private var pending: [String: Pending] = [:]   // rss-Item-ID → Info
    private var triggered: Set<String> = []

    /// Register on tapping a feed-only episode (rss item, ABS show).
    func register(rssItemId: String, showId: String, feed: FeedEpisode) {
        pending[rssItemId] = Pending(showId: showId, feed: feed)
    }

    /// Called by the player on each tick. Triggers the server download once the
    /// registered episode has played ~30 s.
    func playbackTick(itemId: String?, currentTime: Double) {
        guard autoSave, let itemId, currentTime >= 30,
              !triggered.contains(itemId), let info = pending[itemId] else { return }
        triggered.insert(itemId)
        Task { await saveToServer(rssItemId: itemId, info: info) }
    }

    private func saveToServer(rssItemId: String, info: Pending) async {
        let abs = ABSPodcastProvider.shared
        if await abs.downloadEpisode(showId: info.showId, episode: info.feed) != nil { return }

        // Server downloads asynchronously — poll until the episode appears, then handoff.
        for _ in 0..<12 {
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            await abs.refresh()
            if let serverId = abs.serverEpisodeId(showId: info.showId, title: info.feed.title) {
                await migrateProgress(from: rssItemId, to: serverId, duration: info.feed.duration)
                pending[rssItemId] = nil
                return
            }
        }
    }

    /// Move the local/iCloud progress of the rss episode onto the server episode
    /// and write it once to the ABS server.
    private func migrateProgress(from old: String, to new: String, duration: Double) async {
        let d = UserDefaults.standard
        guard let arr = d.array(forKey: AppStorageKeys.localPosition(old)) as? [Double], arr.count == 2 else { return }
        d.set(arr, forKey: AppStorageKeys.localPosition(new))
        d.removeObject(forKey: AppStorageKeys.localPosition(old))
        PodcastCloudSync.shared.reconcile()

        let position = arr[0]
        let dur = duration > 0 ? duration : 0
        try? await ABSPodcastProvider.shared.updateProgress(
            itemId: new, currentTime: position, duration: dur,
            isFinished: dur > 0 && position >= dur - 1
        )
        await ABSPodcastProvider.shared.refreshProgress()
        PodcastProgressStore.shared.reload()
    }
}
