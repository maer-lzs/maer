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
