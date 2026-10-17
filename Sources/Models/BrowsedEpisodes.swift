// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation
import OSLog
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

    /// Internal, so a witness can hold a store of its own; the app holds `shared`.
    init() {}

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

    /// Forgets by the FEED, compared through the one normalisation: a
    /// subscription lands under `https://` and a stripped query while the
    /// browsed show may carry `http://` and its tracking bits, and a
    /// subscription on the server branch has no local show to find.
    func forget(feedURL: String) {
        let key = PodcastSubscriptions.normalizeFeedURL(feedURL)
        byGuid.withLock { map in
            map = map.filter { PodcastSubscriptions.normalizeFeedURL($0.value.show.feedURL) != key }
        }
    }

    func episode(guid: String) -> (show: PodcastShow, episode: PodcastEpisode)? {
        byGuid.withLock { $0[guid] }
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
        var stored = Self.writableRecords(defaults)
        guard stored[guid] == nil else { return }
        stored[guid] = Kept(guid: guid,
                            feedURL: found.show.feedURL,
                            showTitle: found.show.title,
                            episodeTitle: found.episode.title,
                            audioURL: found.episode.audioURL,
                            duration: found.episode.duration,
                            artworkURL: PodcastCover.source(episodeImage: found.episode.imageURL,
                                                            showArtwork: found.show.artworkURL))
        // A duration that is not finite does not encode; then nothing is written.
        guard let data = try? JSONEncoder().encode(stored) else {
            Logger.rss.error("BROWSED kept list not encodable, not written")
            return
        }
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

    /// The kept rows for reading: a list that does not decode reads as none.
    private static func storedRecords(_ defaults: UserDefaults) -> [String: Kept] {
        records(defaults) ?? [:]
    }

    /// The kept rows for a write: a list that stands and does not decode is
    /// set aside first, so the write does not replace it for good (the next
    /// keep would have written the empty list plus one row over it).
    private static func writableRecords(_ defaults: UserDefaults) -> [String: Kept] {
        CorruptStore.setAsideUnreadable([String: Kept].self, defaultsKey: storeKey, defaults: defaults,
                                        label: "BROWSED kept list", log: Logger.rss)
        return records(defaults) ?? [:]
    }

    /// The decoded list, empty when none stands, nil when one stands and
    /// does not decode. Decoded once per stored list: the readers ask for
    /// one guid at a time, and a decode per read would decode the whole
    /// list each time.
    /// The bytes decide whether the kept answer still holds, so a write
    /// from anywhere is seen.
    private static func records(_ defaults: UserDefaults) -> [String: Kept]? {
        guard let data = defaults.data(forKey: storeKey) else { return [:] }
        let id = ObjectIdentifier(defaults)
        let earlier = decoded.withLock { $0[id] }
        if let earlier, earlier.data == data { return earlier.records }
        guard let records = try? JSONDecoder().decode([String: Kept].self, from: data) else { return nil }
        decoded.withLock { $0[id] = (data, records, (earlier?.decodes ?? 0) + 1) }
        return records
    }
    private static let decoded = Mutex<[ObjectIdentifier: (data: Data, records: [String: Kept], decodes: Int)]>([:])

    /// How often the list in `defaults` was decoded, for the witness.
    static func decodeCount(in defaults: UserDefaults) -> Int {
        decoded.withLock { $0[ObjectIdentifier(defaults)]?.decodes ?? 0 }
    }

    /// A subscription takes the show over: the remembered episodes of that
    /// address then belong to the subscription stock, and that is the one truth.
    func forgetListened(feedURL: String, defaults: UserDefaults = .standard) {
        let key = PodcastSubscriptions.normalizeFeedURL(feedURL)
        let all = Self.writableRecords(defaults)
        let stored = all.filter {
            PodcastSubscriptions.normalizeFeedURL($0.value.feedURL) != key
        }
        // A duration that is not finite does not encode; then nothing is written.
        guard let data = try? JSONEncoder().encode(stored) else {
            Logger.rss.error("BROWSED kept list not encodable, not written")
            return
        }
        defaults.set(data, forKey: Self.storeKey)
    }

    #if DEBUG
    func _testReset(defaults: UserDefaults = .standard) {
        byGuid.withLock { $0 = [:] }
        defaults.removeObject(forKey: Self.storeKey)
    }
    #endif
}
