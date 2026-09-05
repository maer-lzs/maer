// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation
import Synchronization

/// Episodes of a show that is being BROWSED without being subscribed.
///
/// An episode's audio address is stated openly in the feed; a subscription is
/// not a precondition for listening. Without this store the resolver would
/// find an episode only in the subscription stock and answer 404 otherwise.
///
/// Two halves with different lifetimes, and the line between them IS the rule:
/// the session half holds every episode that gets looked at, so it can play.
/// It writes nothing. The persisted half holds ONLY episodes that were
/// actually listened to, so their position still resolves after a restart.
/// Browsing and scrolling therefore leave nothing behind; listening leaves
/// exactly one row.
///
/// Without the second half a stored position would be an orphan: the id would
/// no longer resolve after a restart, and the tile would carry no name and
/// would not play.
///
/// `nonisolated` behind one mutex because two very different places ask: the
/// playback resolver (main actor) and the position gate (`ListeningClasses`,
/// pure and called from anywhere).
nonisolated final class BrowsedEpisodes: Sendable {
    static let shared = BrowsedEpisodes()

    /// The whole session state sits behind this one mutex and only ever
    /// leaves it as a copy.
    private let byGuid = Mutex<[String: (show: PodcastShow, episode: PodcastEpisode)]>([:])

    private init() {}

    /// Remembers the episodes of a show that is not subscribed, so they can be
    /// played. Subscribing clears them again. From then on the show belongs to
    /// the subscription stock, and that is the one truth.
    func remember(show: PodcastShow) {
        byGuid.withLock { map in
            for episode in show.episodes { map[episode.guid] = (show, episode) }
        }
    }

    func forget(showId: String) {
        byGuid.withLock { map in
            map = map.filter { $0.value.show.id != showId }
        }
    }

    func episode(guid: String) -> (show: PodcastShow, episode: PodcastEpisode)? {
        byGuid.withLock { $0[guid] }
    }

    /// Is this episode known only from browsing, i.e. not subscribed?
    func isBrowsedOnly(_ itemId: String) -> Bool {
        byGuid.withLock { $0[itemId] != nil }
    }

    // MARK: - The persisted half

    /// What has to survive of a listened episode so its position yields a tile
    /// with a name: the address it lives at, and the little the tile shows. No
    /// subscription, no refresh, no downloads. Just this one episode.
    struct Kept: Codable, Sendable {
        var guid: String
        var feedURL: String
        var showTitle: String
        var episodeTitle: String
        var audioURL: String
        var duration: Double
        var artworkURL: String?
    }

    private static let storeKey = "browsedEpisodesListened"

    /// Writes the episode down. Called where a POSITION comes into being, so
    /// only what was actually listened to is kept.
    func keepListened(guid: String, defaults: UserDefaults = .standard) {
        guard let found = episode(guid: guid), !found.episode.audioURL.isEmpty else { return }
        var stored = Self.storedRecords(defaults)
        guard stored[guid] == nil else { return }
        stored[guid] = Kept(guid: guid,
                            feedURL: found.show.feedURL,
                            showTitle: found.show.title,
                            episodeTitle: found.episode.title,
                            audioURL: found.episode.audioURL,
                            duration: found.episode.duration,
                            artworkURL: found.episode.imageURL ?? found.show.artworkURL)
        guard let data = try? JSONEncoder().encode(stored) else { return }
        defaults.set(data, forKey: Self.storeKey)
    }

    func listened(guid: String, defaults: UserDefaults = .standard) -> Kept? {
        Self.storedRecords(defaults)[guid]
    }

    /// Every kept row: the input of the co-listened rule (`CoListened`).
    func allListened(defaults: UserDefaults = .standard) -> [Kept] {
        Array(Self.storedRecords(defaults).values)
    }

    /// The shows of the session half, each once (the one a refresh fetched
    /// for a co-listened feed among them).
    func sessionShows() -> [PodcastShow] {
        byGuid.withLock { map in
            var seen = Set<String>()
            return map.values.compactMap { seen.insert($0.show.id).inserted ? $0.show : nil }
        }
    }

    private static func storedRecords(_ defaults: UserDefaults) -> [String: Kept] {
        guard let data = defaults.data(forKey: storeKey),
              let stored = try? JSONDecoder().decode([String: Kept].self, from: data)
        else { return [:] }
        return stored
    }

    /// A subscription takes the show over: the remembered episodes of that
    /// address then belong to the subscription stock, and that is the one truth.
    func forgetListened(feedURL: String, defaults: UserDefaults = .standard) {
        let stored = Self.storedRecords(defaults).filter { $0.value.feedURL != feedURL }
        guard let data = try? JSONEncoder().encode(stored) else { return }
        defaults.set(data, forKey: Self.storeKey)
    }

    #if DEBUG
    func _testReset(defaults: UserDefaults = .standard) {
        byGuid.withLock { $0 = [:] }
        defaults.removeObject(forKey: Self.storeKey)
    }
    #endif
}
