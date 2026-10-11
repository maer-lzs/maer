// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation

/// Pure, testable presentation rules for the music-tab playlist cards.
/// The 2×2 mosaic degradation, the metadata line's duration, and the
/// "recently changed first" sort key. Foundation-only.
nonisolated enum PlaylistPresentation {
    /// Whether a playlist card offers to shuffle. Shuffling nothing is not
    /// a shorter shuffle, it is nothing at all, and a control that answers
    /// a tap with nothing is worse than a missing one: there is no way to
    /// tell "did not work" from "did nothing". The way INTO an empty list
    /// stays (its detail pill), so it is never a dead end either.
    static func offersShuffle(trackCount: Int) -> Bool { trackCount > 0 }

    /// What of a playlist is on the device: a server list is ONE download
    /// (its own id), a Mär list is its entries. `anyHere` feeds the
    /// availability rule like a show with one episode downloaded; the
    /// downloaded mark stands only when `allHere`. The card showed neither,
    /// while every tile next to it did. Whether the network is up is not
    /// this rule's question: `MediaAvailability` joins the two.
    struct DownloadState: Equatable {
        let anyHere: Bool
        let allHere: Bool
    }

    static func downloadState(downloaded: [Bool]) -> DownloadState {
        DownloadState(anyHere: downloaded.contains(true),
                      allHere: !downloaded.isEmpty && !downloaded.contains(false))
    }

    /// How many UNIQUE covers the portrait mosaic uses (one big and two
    /// small slots): 0 → tint+glyph, 1 → big cover only,
    /// 2 → big + one small, 3 or more → all three slots. Never more than 3.
    static func mosaicTileCount(_ coverCount: Int) -> Int {
        min(max(coverCount, 0), 3)
    }

    /// Pure, tested: pick the mosaic cover ids from a
    /// playlist's songs. UNIQUE per ALBUM, never per cover-art id. Navidrome
    /// hands every song its own coverArt id (`mf-…`) even when they all show
    /// the same album cover, so deduping by cover id built mosaics of three
    /// identical images. Key: albumId, falling back to the album name, falling
    /// back to the cover id itself (each cover then counts as its own album).
    static func mosaicCoverIDs(_ songs: [(albumKey: String?, coverArt: String?)],
                               limit: Int = 4) -> [String] {
        var seen = Set<String>()
        var ids: [String] = []
        for song in songs {
            guard let art = song.coverArt else { continue }
            let key = song.albumKey ?? art
            guard seen.insert(key).inserted else { continue }
            ids.append(art)
            if ids.count == limit { break }
        }
        return ids
    }

    /// Pure and tested: drop junk playlists. Some Subsonic servers return
    /// `getPlaylists` entries whose `name` is just the raw id (or is empty),
    /// with 0 songs. The card row would render each as an empty-mosaic card, a wall of
    /// blanks. Keep a playlist ONLY when it has a non-empty name that is NOT
    /// equal to its id: real named playlists stay (including genuinely EMPTY
    /// ones. A real empty playlist still has a real name), while name==id and
    /// nameless junk is removed. `songCount` is deliberately NOT the criterion.
    /// THE one filter. Applied where `playlists` is loaded, so every surface
    /// (the playlist card row, the Playlists browse page) is clean.
    static func realPlaylists(_ playlists: [MusicPlaylist]) -> [MusicPlaylist] {
        playlists.filter { playlist in
            let name = (playlist.name ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return !name.isEmpty && name != playlist.id
        }
    }

    /// Total playlist duration → "1:12" (H:MM) when at least an hour, else
    /// "3:45" (M:SS). Used in the metadata pill "18 Titel · 1:12".
    static func durationText(seconds: Int) -> String {
        let s = max(seconds, 0)
        let h = s / 3600, m = (s % 3600) / 60, sec = s % 60
        return h > 0 ? String(format: "%d:%02d", h, m) : String(format: "%d:%02d", m, sec)
    }

    /// The running time a server states for a playlist, in whole seconds;
    /// nil when it states none (Jellyfin without run time ticks, Subsonic
    /// without a duration) or nothing above zero, so the line carries the
    /// count alone instead of "0:00".
    static func knownSeconds(_ duration: Double?) -> Int? {
        guard let duration, duration >= 1 else { return nil }
        return Int(duration)
    }

    /// ISO-8601 `changed` timestamp → Date for the sort; nil when absent/unparsable.
    static func changedDate(_ iso: String?) -> Date? {
        guard let iso, !iso.isEmpty else { return nil }
        return ServerTimestamp.date(iso)
    }

    /// The playlist's most frequent artists (by track count), pure.
    /// Key is case-/diacritic-folded (display keeps the first-seen spelling);
    /// ties keep first appearance; empties drop. The card renders the result
    /// joined into ONE line with native truncation.
    static func topArtists(_ names: [String?], limit: Int = 3) -> [String] {
        var counts: [String: Int] = [:]
        var display: [String: String] = [:]
        var order: [String] = []
        for raw in names {
            guard let name = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !name.isEmpty else { continue }
            let key = name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil).lowercased()
            if counts[key] == nil { order.append(key); display[key] = name }
            counts[key, default: 0] += 1
        }
        return order
            .sorted { a, b in
                let ca = counts[a] ?? 0, cb = counts[b] ?? 0
                return ca == cb
                    ? (order.firstIndex(of: a) ?? 0) < (order.firstIndex(of: b) ?? 0)
                    : ca > cb
            }
            .prefix(limit)
            .compactMap { display[$0] }
    }

    /// Sort playlists newest-changed first; ones without a timestamp sort last,
    /// then stably by their existing order (index tiebreak).
    static func sortedByChanged<T>(_ items: [T], changed: (T) -> Date?) -> [T] {
        items.enumerated().sorted { a, b in
            switch (changed(a.element), changed(b.element)) {
            case let (x?, y?): return x == y ? a.offset < b.offset : x > y
            case (nil, _?): return false
            case (_?, nil): return true
            case (nil, nil): return a.offset < b.offset
            }
        }.map(\.element)
    }
}
