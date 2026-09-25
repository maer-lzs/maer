// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation

/// Every song of one Subsonic server, kept on the device (GT-2). The
/// Subsonic interface has no sorted list of all songs: `search3` with an
/// empty query hands them out in the server's own order, so the list is
/// loaded once, sorted here, and afterwards only what is new is added.
nonisolated struct SongCatalog: Codable, Equatable, Sendable {
    struct Entry: Codable, Equatable, Sendable {
        let id: String
        let title: String?
        let artist: String?
        let album: String?
        let albumId: String?
        let duration: Int?
        let created: String?
        let played: String?
        let playCount: Int?
    }

    var entries: [Entry]
    /// When the list was last loaded WHOLE, in seconds since 1970. The page
    /// says it, so an old list is never mistaken for today's.
    var wholeAt: Double
    /// The server's song count and last scan when the list was taken or
    /// last added to: unchanged means nothing can be new.
    var serverCount: Int?
    var serverLastScan: String?
}

/// What to do with a kept song list before answering. Pure.
nonisolated enum SongCatalogRule {
    enum Step: Equatable {
        /// The kept list stands.
        case keep
        /// Load every song again.
        case whole
        /// Ask for the albums added since the newest song the list holds.
        case addNew(since: Double)
    }

    /// How old a whole list may get before it is loaded whole again. The
    /// play counts and dates in it only change with a whole load, and a
    /// deleted song only leaves with one.
    static let wholeEveryDays = 7

    /// - Parameters:
    ///   - kept: the list on the device, nil when there is none.
    ///   - count, lastScan: the server's `getScanStatus` now; nil when it
    ///     could not be asked or does not say.
    static func step(kept: SongCatalog?, count: Int?, lastScan: String?, now: Double) -> Step {
        guard let kept, !kept.entries.isEmpty else { return .whole }
        if now - kept.wholeAt >= Double(wholeEveryDays) * 86_400 { return .whole }
        // A server that cannot say what changed is asked again in full
        // after a day; before that the list stands.
        guard let count else { return now - kept.wholeAt >= 86_400 ? .whole : .keep }
        if count == kept.serverCount, lastScan == kept.serverLastScan { return .keep }
        // Fewer songs than before: something left, and only a whole load
        // finds out what.
        if let before = kept.serverCount, count < before { return .whole }
        guard let newest = newestAdded(kept) else { return .whole }
        return .addNew(since: newest)
    }

    /// The newest `created` the list holds, the watermark for adding.
    static func newestAdded(_ catalog: SongCatalog) -> Double? {
        catalog.entries.compactMap { SongOrder.seconds($0.created) }.max()
    }

    /// The list with new songs added; a song already there is replaced by
    /// its new form. The order of `entries` does not matter, the page sorts.
    static func adding(_ fresh: [SongCatalog.Entry], to catalog: SongCatalog,
                       count: Int?, lastScan: String?) -> SongCatalog {
        var byId = Dictionary(catalog.entries.map { ($0.id, $0) }) { first, _ in first }
        for entry in fresh { byId[entry.id] = entry }
        var next = catalog
        next.entries = byId.values.sorted { $0.id < $1.id }
        next.serverCount = count
        next.serverLastScan = lastScan
        return next
    }
}
