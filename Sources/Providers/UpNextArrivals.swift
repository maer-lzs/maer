// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation
import OSLog

/// Where a show's new episodes go in Up Next, per show and for all shows,
/// and since when. The choice travels like "Show in New Episodes"; Up Next
/// itself stays on the device, so each device adds on its own refresh. The
/// moment the choice was switched on stays on the device too: it is written
/// here when the person switches, and by the first refresh on a device that
/// adopted the choice from another one. A `store` of nil is the app's
/// settings through `AppStorageKeys`; a test hands its own.
@MainActor
enum UpNextAutoChoice {
    typealias Placement = UpNextAuto.Placement

    private static func read(_ key: String, _ store: UserDefaults?) -> Any? {
        if let store { return store.object(forKey: key) }
        return AppStorageKeys.object(key)
    }

    static func placement(_ showId: String, store: UserDefaults? = nil) -> Placement {
        stored(showId, store: store) ?? general(store: store)
    }

    /// The show's own value, nil when it follows the one for all shows.
    static func stored(_ showId: String, store: UserDefaults? = nil) -> Placement? {
        (read(UpNextAuto.key(showId), store) as? String).flatMap(Placement.init(rawValue:))
    }

    static func general(store: UserDefaults? = nil) -> Placement {
        (read(UpNextAuto.generalKey, store) as? String).flatMap(Placement.init(rawValue:)) ?? .off
    }

    /// The key of the moment that holds for the show: its own, or for a show
    /// that follows, the one for all shows.
    private static func sinceKey(_ showId: String, store: UserDefaults?) -> String {
        stored(showId, store: store) != nil ? UpNextAuto.sinceKey(showId) : UpNextAuto.generalSinceKey
    }

    /// The moment (milliseconds) the show's effective choice went on.
    static func since(_ showId: String, store: UserDefaults? = nil) -> Double? {
        (read(sinceKey(showId, store: store), store) as? NSNumber)?.doubleValue
    }

    /// Switching on, from off or from following all shows, takes the moment
    /// now; switching between top and end keeps it.
    static func setOwn(_ placement: Placement, showId: String, now: Double = Date().timeIntervalSince1970 * 1000) {
        let wasOn = self.placement(showId) != .off
        let key = UpNextAuto.key(showId)
        AppStorageKeys.set(placement.rawValue, for: key)
        AppStorageKeys.noteChoice(placement.rawValue, key: key)
        if placement == .off {
            AppStorageKeys.remove(UpNextAuto.sinceKey(showId))
        } else if !wasOn || AppStorageKeys.double(UpNextAuto.sinceKey(showId)) == nil {
            AppStorageKeys.set(now, for: UpNextAuto.sinceKey(showId))
        }
    }

    static func setGeneral(_ placement: Placement, now: Double = Date().timeIntervalSince1970 * 1000) {
        guard placement != general() else { return }
        let wasOn = general() != .off
        AppStorageKeys.set(placement.rawValue, for: UpNextAuto.generalKey)
        AppStorageKeys.noteChoice(placement.rawValue, key: UpNextAuto.generalKey)
        if placement == .off { AppStorageKeys.remove(UpNextAuto.generalSinceKey) }
        else if !wasOn { AppStorageKeys.set(now, for: UpNextAuto.generalSinceKey) }
    }

    /// The show follows the choice for all shows again, here and on the
    /// other devices; its own moment goes with it.
    static func clear(_ showId: String) {
        AppStorageKeys.remove(UpNextAuto.sinceKey(showId))
        guard AppStorageKeys.string(UpNextAuto.key(showId)) != nil else { return }
        AppStorageKeys.remove(UpNextAuto.key(showId))
        AppStorageKeys.noteChoice(nil, key: UpNextAuto.key(showId))
    }

    /// A choice adopted from another device has no moment here yet: it gets
    /// this refresh's moment, so what arrives now and later counts, not the
    /// backlog. Returns whether a moment was written.
    @discardableResult
    static func noteMissingSince(_ showId: String, now: Double, store: UserDefaults? = nil) -> Bool {
        guard placement(showId, store: store) != .off, since(showId, store: store) == nil else { return false }
        let key = sinceKey(showId, store: store)
        if let store { store.set(now, forKey: key) } else { AppStorageKeys.set(now, for: key) }
        return true
    }
}

/// The one place where a refresh's new episodes go into Up Next. Every way
/// that merges a fresh feed into a followed show hands its pairs here
/// (the fence `UpNextAutoTests` names them); the subscription itself does
/// not, because a show seen for the first time brings its backlog.
@MainActor
enum UpNextArrivals {
    /// `pairs`: each show as it was stored before the fetch and as merged
    /// after it. One write of the queue for all of them.
    static func take(_ pairs: [(stored: PodcastShow, merged: PodcastShow)],
                     queue: PlayQueue?,
                     store: UserDefaults? = nil,
                     now: Double = Date().timeIntervalSince1970 * 1000) {
        guard let queue else { return }
        var arrivals: [UpNextAuto.Arrival] = []
        var episodes: [String: (show: PodcastShow, episode: PodcastEpisode)] = [:]
        for pair in pairs {
            let found = UpNextAuto.arrivals(stored: pair.stored, merged: pair.merged)
            guard !found.isEmpty else { continue }
            // A moment noted now holds for later refreshes; what arrives in
            // this one appeared before it and stays out.
            UpNextAutoChoice.noteMissingSince(pair.merged.id, now: now, store: store)
            arrivals += found
            let byId = Dictionary(pair.merged.episodes.map { ($0.guid, $0) }) { first, _ in first }
            for arrival in found { if let episode = byId[arrival.id] { episodes[arrival.id] = (pair.merged, episode) } }
        }
        guard !arrivals.isEmpty else { return }
        // The one judgement per episode the automatic download asks too:
        // heard and begun both keep an episode out.
        let plan = UpNextAuto.plan(
            arrivals,
            placement: { UpNextAutoChoice.placement($0, store: store) },
            since: { UpNextAutoChoice.since($0, store: store) },
            isUnheard: { id in
                guard let found = episodes[id] else { return false }
                return podcastPlayState(for: podcastLibraryItem(show: found.show, episode: found.episode)) == .unplayed
            },
            isQueued: { queue.contains($0) })
        Logger.library.notice("UPNEXT arrivals=\(arrivals.count) top=\(plan.top.count) end=\(plan.end.count)")
        guard !plan.isEmpty else { return }
        queue.addArrivals(plan)
    }
}
