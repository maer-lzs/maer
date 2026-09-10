// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation

/// The fold that makes one book out of the files of one Jellyfin folder.
///
/// Measured on Jellyfin 12: a folder of files in a `books` library is one
/// `AudioBook` per file, all sharing the folder as `ParentId`, and a bare
/// `Folder` that represents nothing. No element stands for the book. So the
/// files of one folder become ONE book here, keyed by the folder, in
/// `IndexNumber` order with the name as the fallback. A folder with one file
/// stays what it was, keyed by the file, so its listening state and its
/// download do not move. Grouping is by folder, not by `Album`: two books may
/// carry the same album tag, and a book without tags has none.
///
/// The listening state of a folded book is that of a multi-track book: the
/// position of the running file plus the files before it. On the server it
/// lives per element, so reading takes the furthest point any element
/// speaks for, and writing lands on the running element only, with the
/// elements before it played and the ones after it at zero. Pure, so the
/// cases are provable without a server.
nonisolated enum JellyfinBookFold {

    /// One book as the fold sees it.
    struct Group {
        /// The raw Jellyfin id the book is keyed by: the folder of a folded
        /// book, the file itself of a single one.
        let rawId: String
        let isFolded: Bool
        /// In playing order.
        let elements: [JFItem]
    }

    /// Groups `AudioBook` elements into books by folder, keeping the order
    /// the server listed them in for the books themselves. An element
    /// without a folder is its own single book.
    static func fold(_ elements: [JFItem]) -> [Group] {
        var keys: [String] = []
        var byKey: [String: [JFItem]] = [:]
        for element in elements {
            // An orphan gets a key no folder id can collide with.
            let key = element.parentId ?? "\u{0}" + element.id
            if byKey[key] == nil { keys.append(key) }
            byKey[key, default: []].append(element)
        }
        return keys.map { key in
            let members = byKey[key] ?? []
            if members.count == 1, let only = members.first {
                return Group(rawId: only.id, isFolded: false, elements: members)
            }
            return Group(rawId: key, isFolded: true, elements: ordered(members))
        }
    }

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
