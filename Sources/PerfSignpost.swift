// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import MetricKit
import OSLog

/// Every measuring point of the app, in one place. Behind the open gate
/// (`MetricGate`, a build from Xcode and TestFlight) each category writes
/// to a log from `MXMetricManager.makeLogHandle(category:)`, the only logs
/// whose signposts MetricKit keeps: their names come back in the daily
/// payload with a count and a duration. While the gate is closed or
/// undecided, they write to the app's own logs, which Instruments shows
/// and MetricKit does not keep; no log of MetricKit is made then.
///
/// The rare intervals in `snapshotNames` also carry MetricKit's snapshot
/// (`mxSignpost`), so the payload has their CPU time, and only behind the
/// open gate. Apple's header calls that much more expensive than a plain
/// signpost and asks for it sparingly, so the frequent ones (the tick and
/// the stats merge every second, a decode per thumbnail) stay plain and
/// their CPU time stays unknown.
///
/// A site never calls a signposter itself: it calls one of the named
/// functions below, whose parameters are enums and numbers only. So a
/// signpost cannot carry an identifier, a title or an address, and the
/// fence `PerfSignpostFenceTests` holds that no signposter is touched
/// outside this file. `nonisolated` so off-main work can signal.
nonisolated enum PerfSignpost {
    /// The seven categories; the raw value names the log.
    fileprivate enum Category: String, CaseIterable {
        case cover, library, player, sync, feeds, standing, bottomBar = "BottomBar"
    }

    /// Whether the gate let this run measure: set once behind it, read by
    /// every signpost.
    private static let measuring = OSAllocatedUnfairLock(initialState: false)

    /// Opens the measuring points to MetricKit. Called once, behind the
    /// open gate.
    static func measure() {
        measuring.withLock { $0 = true }
    }

    fileprivate static var isMeasuring: Bool {
        measuring.withLock { $0 }
    }

    /// The intervals that carry MetricKit's snapshot, and only these.
    static let snapshotNames = ["syncRound", "standMerge", "feedParse", "downloadedEntries-recompute", "accessRead"]

    /// Every name this file writes, intervals and events. A day's record
    /// names the ones that did not come back.
    static let names = ["tick", "nowPlaying", "statsMerge", "syncLoop", "syncRound", "syncRoundOf", "standMerge",
                        "feedParse", "thumb-hit", "decode", "originalCached", "downloadedEntries-recompute",
                        "standingRead", "accessRead", "barCollapsedFlip"]

    /// An open interval; `end()` closes it under the name it was opened
    /// with, on the log it was opened on.
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
        let player = signposter(.player)
        let state = player.beginInterval("tick", id: player.makeSignpostID(), "playing=\(playing)")
        return Interval { player.endInterval("tick", state) }
    }

    /// The lock screen's now-playing info was set.
    static func nowPlaying(newArtwork: Bool) {
        signposter(.player).emitEvent("nowPlaying", "newArtwork=\(newArtwork)")
    }

    /// The listening stats merged and published.
    static func statsMerge() -> Interval {
        let player = signposter(.player)
        let state = player.beginInterval("statsMerge", id: player.makeSignpostID())
        return Interval { player.endInterval("statsMerge", state) }
    }

    /// One pass of the ten-second loop, playing or paused.
    static func syncLoop(playing: Bool) {
        signposter(.sync).emitEvent("syncLoop", "playing=\(playing)")
    }

    // MARK: - Sync

    /// One round of one family over one carrier. The snapshot carries no
    /// words, so an event at the start names the family and the carrier
    /// for a trace.
    static func syncRound(_ family: Family, _ carrier: Carrier) -> Interval {
        signposter(.sync).emitEvent("syncRoundOf",
                                    "family=\(family.rawValue, privacy: .public) carrier=\(carrier.rawValue, privacy: .public)")
        return snapshotInterval(.sync, "syncRound")
    }

    /// The listening positions merged, from reading both sides to writing.
    static func standMerge() -> Interval {
        snapshotInterval(.sync, "standMerge")
    }

    // MARK: - Feeds

    /// One feed parsed, without the fetch.
    static func feedParse() -> Interval {
        snapshotInterval(.feeds, "feedParse")
    }

    // MARK: - Covers

    /// A thumbnail came from the memory cache.
    static func thumbnailHit() {
        signposter(.cover).emitEvent("thumb-hit")
    }

    /// A thumbnail decoded off the main actor.
    static func coverDecode() -> Interval {
        let cover = signposter(.cover)
        let state = cover.beginInterval("decode", id: cover.makeSignpostID())
        return Interval { cover.endInterval("decode", state) }
    }

    /// A freshly loaded cover went into the memory cache at its original
    /// size, before it is downsampled.
    static func coverOriginalCached(pixelWidth: Int, pixelHeight: Int) {
        signposter(.cover).emitEvent("originalCached", "px=\(pixelWidth)x\(pixelHeight)")
    }

    // MARK: - Library

    /// The Downloaded section's derived list recomputed.
    static func downloadedRecompute() -> Interval {
        snapshotInterval(.library, "downloadedEntries-recompute")
    }

    // MARK: - The map's standing

    /// The map or the service page read the sync standing.
    static func standingRead() {
        signposter(.standing).emitEvent("standingRead")
    }

    /// The service access read from the keychain.
    static func accessRead() -> Interval {
        snapshotInterval(.standing, "accessRead")
    }

    // MARK: - Bottom bar

    /// The bar collapsed or expanded, to set the morphs against scroll
    /// hitches in a device trace.
    static func barCollapsedFlip(collapsed: Bool) {
        signposter(.bottomBar).emitEvent("barCollapsedFlip", "\(collapsed ? "collapse" : "expand", privacy: .public)")
    }
}

/// The app's own logs, one per category: where the signposts go while the
/// gate is closed or undecided.
nonisolated private enum PlainLogs {
    static let signposters = Dictionary(uniqueKeysWithValues: PerfSignpost.Category.allCases.map {
        ($0, OSSignposter(subsystem: AppLogSubsystem.value, category: $0.rawValue))
    })
}

/// The logs MetricKit keeps, one per category. Made the first time a
/// signpost asks for them, which is only behind the open gate.
nonisolated private enum KeptLogs {
    static let logs = Dictionary(uniqueKeysWithValues: PerfSignpost.Category.allCases.map {
        ($0, MXMetricManager.makeLogHandle(category: $0.rawValue))
    })
    static let signposters = logs.mapValues { OSSignposter(logHandle: $0) }
}

/// The signposter of a category: MetricKit's behind the open gate, the
/// app's own otherwise. Outside the enum, like the snapshot below, so the
/// fence on the measuring points' parameters reads only theirs.
nonisolated private func signposter(_ category: PerfSignpost.Category) -> OSSignposter {
    (PerfSignpost.isMeasuring ? KeptLogs.signposters : PlainLogs.signposters)[category] ?? .disabled
}

/// An interval with MetricKit's snapshot at both ends, for the names in
/// `PerfSignpost.snapshotNames` only. While the gate is closed or
/// undecided it is a plain interval on the app's own log.
nonisolated private func snapshotInterval(_ category: PerfSignpost.Category, _ name: StaticString) -> PerfSignpost.Interval {
    guard PerfSignpost.isMeasuring, let log = KeptLogs.logs[category] else {
        let plain = PlainLogs.signposters[category] ?? .disabled
        let state = plain.beginInterval(name, id: plain.makeSignpostID())
        return PerfSignpost.Interval { plain.endInterval(name, state) }
    }
    let id = OSSignpostID(log: log)
    mxSignpost(.begin, log: log, name: name, signpostID: id)
    return PerfSignpost.Interval { mxSignpost(.end, log: log, name: name, signpostID: id) }
}
