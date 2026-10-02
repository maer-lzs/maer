// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation

/// How this device's own stores take Navidrome's new ids: every `sub:` id
/// in the form the server answers to, once per server address. Pure, so
/// each store's rule has a witness; the run itself is `NavidromeRekeyRun`.
///
/// `map` is always the door's `canonicalItemId`, which is the identity on a
/// new id and on every other namespace, so a second pass changes nothing.
nonisolated enum NavidromeRekey {
    /// The marker of a finished pass, per server address. It is set only
    /// after the last store: a pass broken off in the middle runs again
    /// from the start, and the stores it already took stay as they are.
    static func markerKey(server: String) -> String { "navidromeRekeyed.\(server)" }

    /// A list of ids in their new form, order kept. Where an old and a new
    /// id of one title meet (another device or a play after the update put
    /// the new one in already), the first position stays and the later one
    /// is dropped.
    static func rekeyed(_ ids: [String], _ map: (String) -> String) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for id in ids {
            let new = map(id)
            if seen.insert(new).inserted { out.append(new) }
        }
        return out
    }

    /// Seconds per title in their new form; an old and a new key of one
    /// title add up, because both counted real listening.
    static func summed(_ counts: [String: Int], _ map: (String) -> String) -> [String: Int] {
        var out: [String: Int] = [:]
        for (key, seconds) in counts { out[map(key), default: 0] += seconds }
        return out
    }

    /// The keys that change, each with its new form, in a stable order.
    static func moves(_ keys: some Sequence<String>, _ map: (String) -> String) -> [(from: String, to: String)] {
        keys.compactMap { key -> (from: String, to: String)? in
            let new = map(key)
            return new == key ? nil : (from: key, to: new)
        }
        .sorted { $0.from < $1.from }
    }

    /// How many entries of a list change their form.
    static func changedCount(_ ids: some Sequence<String>, _ map: (String) -> String) -> Int {
        ids.reduce(0) { $0 + (map($1) == $1 ? 0 : 1) }
    }

    /// A download's detail under `newId`, every track's song id in its new
    /// form. A music server's song, album or playlist names its songs in the
    /// tracks (`contentUrl` is the raw song id), and those change even when
    /// the holder's own id does not; any other download keeps its tracks.
    static func downloadDetail(_ detail: LibraryItemDetail, id newId: String,
                               holder itemId: String, _ map: (String) -> String) -> LibraryItemDetail {
        var tracks = detail.media.tracks
        if ItemNamespace.songHolderNamespace(itemId) != nil || ItemNamespace.isServerSong(itemId),
           let namespace = ItemNamespace.of(itemId) {
            let songPrefix = ItemNamespace.serverSongId(namespace: namespace, rawId: "")
            tracks = tracks?.map { track in
                let mapped = map(ItemNamespace.serverSongId(namespace: namespace, rawId: track.contentUrl))
                guard mapped.hasPrefix(songPrefix) else { return track }
                return ABSAudioTrack(index: track.index, startOffset: track.startOffset, duration: track.duration,
                                     contentUrl: String(mapped.dropFirst(songPrefix.count)), metadata: track.metadata)
            }
        }
        let media = LibraryItemMedia(metadata: detail.media.metadata, duration: detail.media.duration,
                                     chapters: detail.media.chapters, tracks: tracks, episodes: detail.media.episodes)
        return LibraryItemDetail(id: newId, media: media, userMediaProgress: detail.userMediaProgress)
    }
}
