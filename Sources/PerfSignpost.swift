// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import MetricKit
import OSLog

/// Every measuring point of the app, in one place. Each category writes to
/// a log from `MXMetricManager.makeLogHandle(category:)`, the only logs
/// whose signposts MetricKit keeps: their names come back in the daily
/// payload with a count and a duration. They show in Instruments as well.
///
/// The rare intervals in `snapshotNames` also carry MetricKit's snapshot
/// (`mxSignpost`), so the payload has their CPU time. Apple's header calls
/// that much more expensive than a plain signpost and asks for it
/// sparingly, so the frequent ones (the tick and the stats merge every
/// second, a decode per thumbnail) stay plain and their CPU time stays
/// unknown.
///
/// A site never calls a signposter itself: it calls one of the named
/// functions below, whose parameters are enums and numbers only. So a
/// signpost cannot carry an identifier, a title or an address, and the
/// fence `PerfSignpostFenceTests` holds that no signposter is touched
/// outside this file. `nonisolated` so off-main work can signal.
nonisolated enum PerfSignpost {
    private static let coverLog = MXMetricManager.makeLogHandle(category: "cover")
    private static let libraryLog = MXMetricManager.makeLogHandle(category: "library")
    private static let playerLog = MXMetricManager.makeLogHandle(category: "player")
    private static let syncLog = MXMetricManager.makeLogHandle(category: "sync")
    private static let feedsLog = MXMetricManager.makeLogHandle(category: "feeds")
    private static let standingLog = MXMetricManager.makeLogHandle(category: "standing")
    private static let bottomBarLog = MXMetricManager.makeLogHandle(category: "BottomBar")

    private static let cover = OSSignposter(logHandle: coverLog)
    private static let player = OSSignposter(logHandle: playerLog)
    private static let sync = OSSignposter(logHandle: syncLog)
    private static let standing = OSSignposter(logHandle: standingLog)
    private static let bottomBar = OSSignposter(logHandle: bottomBarLog)

    /// The intervals that carry MetricKit's snapshot, and only these.
    static let snapshotNames = ["syncRound", "standMerge", "feedParse", "downloadedEntries-recompute", "accessRead"]

    /// Every name this file writes, intervals and events. A day's record
    /// names the ones that did not come back.
    static let names = ["tick", "nowPlaying", "statsMerge", "syncLoop", "syncRound", "syncRoundOf", "standMerge",
                        "feedParse", "thumb-hit", "decode", "originalCached", "downloadedEntries-recompute",
                        "standingRead", "accessRead", "barCollapsedFlip"]

    /// An open interval; `end()` closes it under the name it was opened
    /// with.
    struct Interval: Sendable {
        fileprivate let close: @Sendable () -> Void
        func end() { close() }
    }

    /// What a sync round moves. Fixed names, never a key.
    enum Family: String, Sendable {
        case stand, stats, playlists, choices, positions, userChoices, feedAuth, gpodder
        case service, serverProgress, claim, claimPoll
    }

    /// Which way a round goes. Fixed names, never an address.
    enum Carrier: String, Sendable {
        case keyValue, cloudKit, maerSync, server, local
    }

    // MARK: - Player

    /// The second of the player: its whole work on the main actor.
    static func tick(playing: Bool) -> Interval {
        let id = player.makeSignpostID()
        let state = player.beginInterval("tick", id: id, "playing=\(playing)")
        return Interval { player.endInterval("tick", state) }
    }

    /// The lock screen's now-playing info was set.
    static func nowPlaying(newArtwork: Bool) {
        player.emitEvent("nowPlaying", "newArtwork=\(newArtwork)")
    }

    /// The listening stats merged and published.
    static func statsMerge() -> Interval {
        let id = player.makeSignpostID()
        let state = player.beginInterval("statsMerge", id: id)
        return Interval { player.endInterval("statsMerge", state) }
    }

    /// One pass of the ten-second loop, playing or paused.
    static func syncLoop(playing: Bool) {
        sync.emitEvent("syncLoop", "playing=\(playing)")
    }

    // MARK: - Sync

    /// One round of one family over one carrier. The snapshot carries no
    /// words, so an event at the start names the family and the carrier
    /// for a trace.
    static func syncRound(_ family: Family, _ carrier: Carrier) -> Interval {
        sync.emitEvent("syncRoundOf", "family=\(family.rawValue, privacy: .public) carrier=\(carrier.rawValue, privacy: .public)")
        return snapshotInterval(syncLog, "syncRound")
    }

    /// The listening positions merged, from reading both sides to writing.
    static func standMerge(entries: Int) -> Interval {
        snapshotInterval(syncLog, "standMerge")
    }

    // MARK: - Feeds

    /// One feed parsed, without the fetch.
    static func feedParse(bytes: Int) -> Interval {
        snapshotInterval(feedsLog, "feedParse")
    }

    // MARK: - Covers

    /// A thumbnail came from the memory cache.
    static func thumbnailHit() {
        cover.emitEvent("thumb-hit")
    }

    /// A thumbnail decoded off the main actor.
    static func coverDecode() -> Interval {
        let id = cover.makeSignpostID()
        let state = cover.beginInterval("decode", id: id)
        return Interval { cover.endInterval("decode", state) }
    }

    /// A freshly loaded cover went into the memory cache at its original
    /// size, before it is downsampled.
    static func coverOriginalCached(pixelWidth: Int, pixelHeight: Int) {
        cover.emitEvent("originalCached", "px=\(pixelWidth)x\(pixelHeight)")
    }

    // MARK: - Library

    /// The Downloaded section's derived list recomputed.
    static func downloadedRecompute() -> Interval {
        snapshotInterval(libraryLog, "downloadedEntries-recompute")
    }

    // MARK: - The map's standing

    /// The map or the service page read the sync standing.
    static func standingRead() {
        standing.emitEvent("standingRead")
    }

    /// The service access read from the keychain.
    static func accessRead() -> Interval {
        snapshotInterval(standingLog, "accessRead")
    }

    // MARK: - Bottom bar

    /// The bar collapsed or expanded, to set the morphs against scroll
    /// hitches in a device trace.
    static func barCollapsedFlip(collapsed: Bool) {
        bottomBar.emitEvent("barCollapsedFlip", "\(collapsed ? "collapse" : "expand", privacy: .public)")
    }
}

/// An interval with MetricKit's snapshot at both ends, for the names in
/// `PerfSignpost.snapshotNames` only. Outside the enum, so the fence on
/// the measuring points' parameters reads only theirs.
nonisolated private func snapshotInterval(_ log: OSLog, _ name: StaticString) -> PerfSignpost.Interval {
    let id = OSSignpostID(log: log)
    mxSignpost(.begin, log: log, name: name, signpostID: id)
    return PerfSignpost.Interval { mxSignpost(.end, log: log, name: name, signpostID: id) }
}
