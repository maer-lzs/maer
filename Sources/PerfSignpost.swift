// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import OSLog

/// Every measuring point of the app, in one place. Signposts show in
/// Instruments (Logging or Points of Interest, subsystem the app's bundle
/// id) and cost next to nothing while nobody records.
///
/// A site never calls a signposter itself: it calls one of the named
/// functions below, whose parameters are enums and numbers only. So a
/// signpost cannot carry an identifier, a title or an address, and the
/// fence `PerfSignpostFenceTests` holds that no signposter is touched
/// outside this file. `nonisolated` so off-main work can signal.
nonisolated enum PerfSignpost {
    private static let cover = OSSignposter(subsystem: AppLogSubsystem.value, category: "cover")
    private static let library = OSSignposter(subsystem: AppLogSubsystem.value, category: "library")
    private static let player = OSSignposter(subsystem: AppLogSubsystem.value, category: "player")
    private static let sync = OSSignposter(subsystem: AppLogSubsystem.value, category: "sync")
    private static let feeds = OSSignposter(subsystem: AppLogSubsystem.value, category: "feeds")
    private static let standing = OSSignposter(subsystem: AppLogSubsystem.value, category: "standing")
    private static let bottomBar = OSSignposter(subsystem: AppLogSubsystem.value, category: "BottomBar")

    /// An open interval; `end()` closes it under the name it was opened
    /// with.
    struct Interval: Sendable {
        fileprivate let signposter: OSSignposter
        fileprivate let state: OSSignpostIntervalState
        fileprivate let close: @Sendable (OSSignposter, OSSignpostIntervalState) -> Void
        func end() { close(signposter, state) }
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
        return Interval(signposter: player, state: state) { $0.endInterval("tick", $1) }
    }

    /// The lock screen's now-playing info was set.
    static func nowPlaying(newArtwork: Bool) {
        player.emitEvent("nowPlaying", "newArtwork=\(newArtwork)")
    }

    /// The listening stats merged and published.
    static func statsMerge() -> Interval {
        let id = player.makeSignpostID()
        let state = player.beginInterval("statsMerge", id: id)
        return Interval(signposter: player, state: state) { $0.endInterval("statsMerge", $1) }
    }

    /// One pass of the ten-second loop, playing or paused.
    static func syncLoop(playing: Bool) {
        sync.emitEvent("syncLoop", "playing=\(playing)")
    }

    // MARK: - Sync

    /// One round of one family over one carrier.
    static func syncRound(_ family: Family, _ carrier: Carrier) -> Interval {
        let id = sync.makeSignpostID()
        let state = sync.beginInterval("syncRound", id: id,
                                       "family=\(family.rawValue, privacy: .public) carrier=\(carrier.rawValue, privacy: .public)")
        return Interval(signposter: sync, state: state) { $0.endInterval("syncRound", $1) }
    }

    /// The listening positions merged, from reading both sides to writing.
    static func standMerge(entries: Int) -> Interval {
        let id = sync.makeSignpostID()
        let state = sync.beginInterval("standMerge", id: id, "entries=\(entries)")
        return Interval(signposter: sync, state: state) { $0.endInterval("standMerge", $1) }
    }

    // MARK: - Feeds

    /// One feed parsed, without the fetch.
    static func feedParse(bytes: Int) -> Interval {
        let id = feeds.makeSignpostID()
        let state = feeds.beginInterval("feedParse", id: id, "bytes=\(bytes)")
        return Interval(signposter: feeds, state: state) { $0.endInterval("feedParse", $1) }
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
        return Interval(signposter: cover, state: state) { $0.endInterval("decode", $1) }
    }

    /// A freshly loaded cover went into the memory cache at its original
    /// size, before it is downsampled.
    static func coverOriginalCached(pixelWidth: Int, pixelHeight: Int) {
        cover.emitEvent("originalCached", "px=\(pixelWidth)x\(pixelHeight)")
    }

    // MARK: - Library

    /// The Downloaded section's derived list recomputed.
    static func downloadedRecompute() -> Interval {
        let id = library.makeSignpostID()
        let state = library.beginInterval("downloadedEntries-recompute", id: id)
        return Interval(signposter: library, state: state) { $0.endInterval("downloadedEntries-recompute", $1) }
    }

    // MARK: - The map's standing

    /// The map or the service page read the sync standing.
    static func standingRead() {
        standing.emitEvent("standingRead")
    }

    /// The service access read from the keychain.
    static func accessRead() -> Interval {
        let id = standing.makeSignpostID()
        let state = standing.beginInterval("accessRead", id: id)
        return Interval(signposter: standing, state: state) { $0.endInterval("accessRead", $1) }
    }

    // MARK: - Bottom bar

    /// The bar collapsed or expanded, to set the morphs against scroll
    /// hitches in a device trace.
    static func barCollapsedFlip(collapsed: Bool) {
        bottomBar.emitEvent("barCollapsedFlip", "\(collapsed ? "collapse" : "expand", privacy: .public)")
    }
}
