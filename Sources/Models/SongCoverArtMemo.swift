// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation

/// The cover-art id a music server names for each of its songs
/// (`coverArt`), kept across sessions. A song's own id is no cover id on
/// every server: gonic answers `getCoverArt` for a song id (`tr-…`) with
/// error 70 and names the album's cover (`al-…`) in the song. A song met
/// again later (the queue, a device playlist, a download) asks the address
/// the server named for it.
///
/// One server at a time: the memory belongs to the server it was learned
/// from and starts empty for another. Capped, oldest first out; a song
/// `keeps` holds stays, because a kept cover stands under its address.
nonisolated struct SongCoverArtMemo: Codable, Equatable {
    nonisolated static let storeKey = "subsonicSongCoverArt"
    static let cap = 3000

    /// What a learned answer did to the memory.
    enum Change: Equatable {
        case same
        /// The song's cover id is new or changed; the one it had before.
        case learned(previous: String?)
    }

    let server: String
    /// Song ids, oldest first.
    private(set) var order: [String] = []
    private(set) var coverArt: [String: String] = [:]

    init(server: String) { self.server = server }

    enum CodingKeys: String, CodingKey { case server, order, coverArt }

    /// Written by hand: a field missing from a kept memory reads as empty,
    /// and the order names each held song once, the ones it lacks at its end.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        server = try c.decode(String.self, forKey: .server)
        let art = try c.decodeIfPresent([String: String].self, forKey: .coverArt) ?? [:]
        var seen: Set<String> = []
        let kept = (try c.decodeIfPresent([String].self, forKey: .order) ?? [])
            .filter { art[$0] != nil && seen.insert($0).inserted }
        order = kept + art.keys.filter { !seen.contains($0) }.sorted()
        coverArt = art
    }

    func coverArt(of songId: String) -> String? { coverArt[songId] }

    mutating func learn(songId: String, coverArt art: String?,
                        keeps: (String) -> Bool = { _ in false }) -> Change {
        guard let art, !art.isEmpty, !songId.isEmpty else { return .same }
        let previous = coverArt[songId]
        guard previous != art else { return .same }
        if previous == nil { order.append(songId) }
        coverArt[songId] = art
        trim(keeps)
        return .learned(previous: previous)
    }

    private mutating func trim(_ keeps: (String) -> Bool) {
        var index = 0
        while order.count > Self.cap, index < order.count {
            if keeps(order[index]) {
                index += 1
            } else {
                coverArt[order.remove(at: index)] = nil
            }
        }
    }

    /// The memory of `server`; empty when none is kept or the kept one
    /// belongs to another server.
    static func load(server: String, defaults: UserDefaults = AppStorageKeys.store) -> SongCoverArtMemo {
        guard let data = defaults.data(forKey: storeKey),
              // bearable, because an unreadable memory only asks each song's cover once more; the next write replaces it
              let kept = try? JSONDecoder().decode(SongCoverArtMemo.self, from: data),
              kept.server == server else { return SongCoverArtMemo(server: server) }
        return kept
    }

    func save(defaults: UserDefaults = AppStorageKeys.store) {
        // bearable, because ids and text always encode; a failure would only keep the older memory
        guard let data = try? JSONEncoder().encode(self) else { return }
        defaults.set(data, forKey: Self.storeKey)
    }
}

/// The songs a server gave no answer for in this session, so a pass that
/// learns covers does not ask them again on every appearance. It belongs to
/// one server like the memory: another server, or none after signing out,
/// starts empty. Kept in memory only and capped, so the next session asks
/// each of them once more.
nonisolated struct UnansweredSongs: Equatable {
    static let cap = SongCoverArtMemo.cap

    let server: String
    private(set) var ids: Set<String> = []

    init(server: String) { self.server = server }

    /// This set when it belongs to `server`, else an empty one for it.
    func belonging(to server: String) -> UnansweredSongs {
        self.server == server ? self : UnansweredSongs(server: server)
    }

    func contains(_ songId: String) -> Bool { ids.contains(songId) }

    mutating func note(_ songIds: some Sequence<String>) {
        for songId in songIds where ids.count < Self.cap { ids.insert(songId) }
    }

    /// The songs of `songIds` a pass asks: each once, in order, with no
    /// learned cover, not asked by a running pass and not unanswered here,
    /// at most `limit`.
    static func toAsk(_ songIds: [String], known: (String) -> Bool, asking: Set<String>,
                      unanswered: UnansweredSongs, limit: Int) -> [String] {
        var seen: Set<String> = []
        return Array(songIds
            .filter { !known($0) && !asking.contains($0) && !unanswered.contains($0) && seen.insert($0).inserted }
            .prefix(limit))
    }
}
