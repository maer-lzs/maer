// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation

/// When a playlist was last heard on this device, by its id: the moment
/// "Listen Again" ranks an own list by, and the one a server playlist
/// shuffled from its card leaves (an opened one has its stand). Only the
/// newest `keep` are held. They travel one statement per list
/// (`playlistPlay.<id>`), and both devices keep the newest `keep` of both.
nonisolated enum PlaylistPlays {
    static let keep = 50

    /// The moments with `id` heard at `atMs`, the newest `keep` of them.
    static func noting(_ id: String, atMs: Double, in moments: [String: Double]) -> [String: Double] {
        var next = moments
        next[id] = atMs
        guard next.count > keep else { return next }
        let kept = next.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.prefix(keep)
        return Dictionary(uniqueKeysWithValues: kept.map { ($0.key, $0.value) })
    }

    /// The stored value as moments. A form this build does not know, or a
    /// broken one, reads as none.
    static func decoded(_ raw: Any?) -> [String: Double] {
        guard let table = raw as? [String: Any] else { return [:] }
        // A table or a list inside is another form (a later build's), not
        // a broken entry: none of it is read.
        if table.values.contains(where: { $0 is [String: Any] || $0 is [Any] }) { return [:] }
        var moments: [String: Double] = [:]
        for (id, value) in table {
            // A number is a moment; anything else is a form this build
            // does not know and is passed over.
            guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
                  number.doubleValue.isFinite, number.doubleValue > 0 else { continue }
            moments[id] = number.doubleValue
        }
        return moments
    }

    /// The moments from the statements of the document: both devices', the
    /// newest `keep`. A tombstone is no moment; a statement of another kind
    /// is a form this build does not know and is passed over.
    static func merged(elements: [(id: String, entry: UserChoiceEntry)]) -> [String: Double] {
        var moments: [String: Double] = [:]
        for element in elements {
            guard case .double(let moment)? = element.entry.value, moment.isFinite, moment > 0 else { continue }
            moments[element.id] = max(moment, moments[element.id] ?? 0)
        }
        guard moments.count > keep else { return moments }
        let kept = moments.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.prefix(keep)
        return Dictionary(uniqueKeysWithValues: kept.map { ($0.key, $0.value) })
    }
}

/// The device's moments (`AppStorageKeys.playlistPlays`).
@MainActor
enum PlaylistPlaysStore {
    static func moments(defaults: UserDefaults = .standard) -> [String: Double] {
        PlaylistPlays.decoded(defaults.object(forKey: AppStorageKeys.playlistPlays))
    }

    static func note(_ id: String, atMs: Double = Date().timeIntervalSince1970 * 1000,
                     defaults: UserDefaults = .standard) {
        defaults.set(PlaylistPlays.noting(id, atMs: atMs, in: moments(defaults: defaults)), forKey: AppStorageKeys.playlistPlays)
        // The moment travels like a heard station, and the rows read it
        // at once; sent with the store, so a witness can tell it.
        UserChoiceCloudSync.shared.notePlaylistPlay(id: id)
        NotificationCenter.default.post(name: .continueHiddenChanged, object: defaults)
    }
}
