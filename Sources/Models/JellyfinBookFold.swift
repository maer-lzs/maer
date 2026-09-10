// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation

/// The fold that makes one book out of the files of one Jellyfin book.
///
/// Measured on Jellyfin 12: every file in a `books` library is one
/// `AudioBook` with its folder as `ParentId`, whatever the folder is. A book
/// folder holds the files of one book; an author folder, or the library's
/// own root folder, holds several single-file books side by side. The
/// folder alone cannot tell those apart, the album tag can: the files of
/// ONE book share it, different books carry different ones. So the rule is
/// the pair: the files of one folder that carry the SAME album tag are one
/// book, keyed by the folder and the tag, in `IndexNumber` order with the
/// name as the fallback. Files with different tags stay separate books;
/// files without a tag stay single-file books too, on the safe side, and
/// the listing says so for a folder that holds several of them. A group of
/// one file stays what it was, keyed by the file, so its listening state
/// and its download do not move. Nothing that is its own book today ever
/// shares its state with another through the fold.
///
/// The listening state of a folded book is that of a multi-track book: the
/// position of the running file plus the files before it. On the server it
/// lives per element, so reading takes the furthest point any element
/// speaks for, and writing lands on the running element only, with the
/// elements before it played and the ones after it at zero. Those
/// neighbours are the book's own files and nothing else, because the group
/// is. Pure, so the cases are provable without a server.
nonisolated enum JellyfinBookFold {

    /// One book as the fold sees it.
    struct Group {
        /// The raw Jellyfin-side id the book is keyed by: the file itself
        /// of a single one, `<folder>-<album hash>` of a folded one.
        let rawId: String
        let isFolded: Bool
        /// In playing order.
        let elements: [JFItem]
    }

    /// Groups `AudioBook` elements into books by folder and album tag,
    /// keeping the order the server listed them in for the books
    /// themselves. An element without a folder or without a tag is its own
    /// single book.
    static func fold(_ elements: [JFItem]) -> [Group] {
        var keys: [String] = []
        var byKey: [String: [JFItem]] = [:]
        for element in elements {
            let key: String
            if let parent = element.parentId, let album = element.album, !album.isEmpty {
                key = parent + "\u{1}" + album
            } else {
                // Its own group, under a key no folder id can collide with.
                key = "\u{0}" + element.id
            }
            if byKey[key] == nil { keys.append(key) }
            byKey[key, default: []].append(element)
        }
        return keys.map { key in
            let members = byKey[key] ?? []
            if members.count == 1, let only = members.first {
                return Group(rawId: only.id, isFolded: false, elements: members)
            }
            let ordered = ordered(members)
            let first = ordered[0]
            return Group(rawId: foldedRawId(parentId: first.parentId ?? "", album: first.album ?? ""),
                         isFolded: true, elements: ordered)
        }
    }

    /// Folders that hold several files without an album tag. They stay
    /// single-file books, and the listing names them, so an untagged book
    /// folder is seen rather than silently split.
    static func untaggedFolders(_ elements: [JFItem]) -> [String: Int] {
        var counts: [String: Int] = [:]
        for element in elements where element.album?.isEmpty != false {
            if let parent = element.parentId { counts[parent, default: 0] += 1 }
        }
        return counts.filter { $0.value > 1 }
    }

    /// True when a listing of several elements carries no folder at all.
    /// Then the fold cannot see anything, and that must be said, because
    /// it would otherwise do nothing without a word.
    static func isBlind(_ elements: [JFItem]) -> Bool {
        elements.count > 1 && elements.allSatisfy { $0.parentId == nil }
    }

    // MARK: - The folded id

    /// `<folder>-<album hash>`: the folder alone would be ambiguous for a
    /// folder that holds more than one book, so the tag travels in the id
    /// as a stable hash. A file's own id is 32 hex characters without a
    /// dash, so it never parses as this.
    static func foldedRawId(parentId: String, album: String) -> String {
        parentId + "-" + albumHash(album)
    }

    static func parseFoldedRawId(_ raw: String) -> (parentId: String, albumHash: String)? {
        guard let dash = raw.lastIndex(of: "-") else { return nil }
        let parent = String(raw[..<dash])
        let hash = String(raw[raw.index(after: dash)...])
        guard !parent.isEmpty, hash.count == 16,
              hash.allSatisfy({ $0.isHexDigit }) else { return nil }
        return (parent, hash)
    }

    /// FNV-1a over the tag's UTF-8, 64 bits as 16 hex digits. The same on
    /// every device, and nothing beyond Foundation.
    static func albumHash(_ album: String) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in album.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        return String(format: "%016llx", hash)
    }

    // MARK: - Order, names

    /// `IndexNumber` first; elements without one come after, by name; the
    /// id breaks the last tie so the order is the same on every device.
    static func ordered(_ elements: [JFItem]) -> [JFItem] {
        elements.sorted { a, b in
            let ai = a.indexNumber ?? Int.max, bi = b.indexNumber ?? Int.max
            if ai != bi { return ai < bi }
            let an = a.name ?? "", bn = b.name ?? ""
            if an != bn { return an.localizedStandardCompare(bn) == .orderedAscending }
            return a.id < b.id
        }
    }

    /// True when a folded book has an element without a track number, which
    /// the order then took from the name. Worth a log line, never a stop.
    static func lacksIndex(_ elements: [JFItem]) -> Bool {
        elements.contains { $0.indexNumber == nil }
    }

    /// The title and author of a folded book: the album tag, else the folder's
    /// name, else the first file's name; the album artist, else the first
    /// artist of the first file.
    static func title(of elements: [JFItem], folderName: String?) -> String? {
        elements.first?.album ?? folderName ?? elements.first?.name
    }

    static func author(of elements: [JFItem]) -> String? {
        elements.first?.albumArtist ?? elements.first?.artists?.first
    }

    // MARK: - Listening state

    /// The book's position from the per-element state: the furthest point
    /// any element speaks for. A played element counts as its whole length,
    /// an element with a position as the track start plus that position
    /// (never past the track's end). Nil when no element says anything.
    /// Finished when every element is played.
    static func position(elements: [JFItem], tracks: [ABSAudioTrack], total: Double)
        -> (currentTime: Double, isFinished: Bool)? {
        var furthest: Double?
        for (index, element) in elements.enumerated() where index < tracks.count {
            let start = TrackMath.trackStart(index: index, tracks: tracks, bookDuration: total)
            let length = tracks[index].duration ?? 0
            let point: Double
            if element.userData?.played == true {
                point = start + length
            } else if let ticks = element.userData?.playbackPositionTicks, ticks > 0 {
                point = start + min(ticks / 10_000_000, length)
            } else {
                continue
            }
            furthest = max(furthest ?? 0, point)
        }
        guard let currentTime = furthest else { return nil }
        let finished = !elements.isEmpty && elements.allSatisfy { $0.userData?.played == true }
        return (currentTime, finished)
    }

    /// Where a book time lands: the running track and the position inside it.
    struct WritePlan: Equatable {
        let index: Int
        let withinTrack: Double
    }

    static func writePlan(currentTime: Double, tracks: [ABSAudioTrack], total: Double) -> WritePlan {
        let index = TrackMath.trackIndex(for: currentTime, tracks: tracks, bookDuration: total)
        let start = TrackMath.trackStart(index: index, tracks: tracks, bookDuration: total)
        return WritePlan(index: index, withinTrack: max(0, currentTime - start))
    }
}
