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

    // MARK: - The choices that travel

    /// The choice families whose key carries an item id after its prefix.
    static let itemKeyedChoicePrefixes = ["playbackRate.", PlayedTail.prefix, UserChoiceCatalog.hiddenPrefix]
    /// The choices whose value is an item id.
    static let itemValuedChoices: Set<String> = [AppStorageKeys.lastPlayedItemId]

    /// A choice key with its item id in the new form; any other key unchanged.
    static func choiceKey(_ key: String, _ map: (String) -> String) -> String {
        guard let prefix = itemKeyedChoicePrefixes.first(where: { key.hasPrefix($0) }) else { return key }
        return prefix + map(String(key.dropFirst(prefix.count)))
    }

    /// Choice statements read with their keys and ids in the new form. Where
    /// an old and a new key land on one, the later statement stands; on an
    /// equal moment the one already under the new key, then the smaller key,
    /// so every device reads the same. The old key itself is left where it
    /// is: a device on an older build keeps writing it, and a key taken out
    /// would come back from there on every round.
    static func foldedChoices(_ entries: [String: UserChoiceEntry],
                              _ map: (String) -> String) -> [String: UserChoiceEntry] {
        var out: [String: (entry: UserChoiceEntry, from: String)] = [:]
        for (key, entry) in entries {
            let newKey = choiceKey(key, map)
            var mapped = entry
            if itemValuedChoices.contains(newKey), case .string(let id)? = entry.value {
                mapped.value = .string(map(id))
            }
            if let held = out[newKey] {
                let wins = mapped.t != held.entry.t ? mapped.t > held.entry.t
                    : prefers(key, over: held.from, newKey: newKey)
                guard wins else { continue }
            }
            out[newKey] = (mapped, key)
        }
        return out.mapValues(\.entry)
    }

    /// The one collision rule where an old and a new key land on one: the
    /// key already in the new form wins, else the smaller key, so every
    /// device reads the same.
    static func prefers(_ key: String, over held: String, newKey: String) -> Bool {
        let native = key == newKey, heldNative = held == newKey
        return native != heldNative ? native : key < held
    }

    // MARK: - The Mär playlists

    /// Values keyed by item id, the keys in the new form. Where an old and a
    /// new key meet, the value already under the new key stays, else the
    /// smaller old key's, so every device reads the same.
    static func keyed<Value>(_ values: [String: Value], _ map: (String) -> String) -> [String: Value] {
        var out: [String: (value: Value, from: String)] = [:]
        for (key, value) in values {
            let newKey = map(key)
            if let held = out[newKey] {
                guard prefers(key, over: held.from, newKey: newKey) else { continue }
            }
            out[newKey] = (value, key)
        }
        return out.mapValues(\.value)
    }

    /// Moments keyed by item id, the keys in the new form; an old and a new
    /// key keep the later moment.
    static func moments(_ values: [String: Double], _ map: (String) -> String) -> [String: Double] {
        var out: [String: Double] = [:]
        for (key, at) in values { out[map(key)] = max(out[map(key)] ?? at, at) }
        return out
    }

    /// One Mär playlist with every entry in the new form: the entries by the
    /// list rule, titles and carried items by their keys (a carried item
    /// names its id inside too), removal and add moments the later one.
    /// Then read by the merge's own rule, so an entry whose old form came
    /// back from a device on an older build, while its new form carries a
    /// removal, stands out as removed here and is not compared as present.
    /// A list in which no id changes is handed back untouched.
    static func playlist(_ entry: MaerPlaylistMerge.Entry, _ map: (String) -> String) -> MaerPlaylistMerge.Entry {
        let ids = entry.itemIds + Array(entry.titles.keys) + Array(entry.snapshots.keys)
            + entry.snapshots.values.map(\.id) + Array(entry.removed.keys) + Array(entry.added.keys)
        guard ids.contains(where: { map($0) != $0 }) else { return entry }
        var mapped = entry
        mapped.itemIds = rekeyed(entry.itemIds, map)
        mapped.titles = keyed(entry.titles, map)
        mapped.snapshots = keyed(entry.snapshots, map).mapValues { item in
            var item = item
            item.id = map(item.id)
            return item
        }
        mapped.removed = moments(entry.removed, map)
        mapped.added = moments(entry.added, map)
        return MaerPlaylistMerge.unite(mapped, mapped)
    }

    /// Every list of a carrier's snapshot read in the new form.
    static func playlists(_ snapshot: MaerPlaylistMerge.Snapshot,
                          _ map: (String) -> String) -> MaerPlaylistMerge.Snapshot {
        MaerPlaylistMerge.Snapshot(lists: snapshot.lists.mapValues { playlist($0, map) },
                                   tombstones: snapshot.tombstones)
    }
}
