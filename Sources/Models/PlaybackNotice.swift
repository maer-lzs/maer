// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation

/// A short notice about playback: where the current state comes from, how
/// it is saved, or why playback stopped. Fixed, checked labels instead of
/// free text. Every notice goes into the log; which ones show as the pill,
/// and for how long, says `NoticeRule`.
nonisolated enum PlaybackNotice: Equatable, Sendable {
    case saved
    case serverAdopted
    case localUsed
    case queued
    case offline
    case conflict
    case trackFailed
    case streamFailed
    /// The playing item could not be loaded; the cause picks the symbol.
    case loadFailed(NoticeCause)
    /// A downloaded file could not be read; the track plays on from the server.
    case downloadUnreadable
    /// A downloaded file could not be read and nothing can take over.
    case downloadUnreadableOffline
    /// Saving the position failed for another reason than the network
    /// (an expired sign-in, a server error).
    case syncFailed
    /// A title could not be opened; the sentence says why, the cause picks
    /// the symbol.
    case openFailed(String, NoticeCause)
    /// The player holds a title it cannot play (no track, not loadable, no
    /// audio session); the sentence says which.
    case cannotPlay(String)
    /// Playback waits on a stream that stopped delivering; it stands while
    /// the wait lasts.
    case waitingForNetwork

    /// The case without its payload, so a table can name every case and a
    /// new one without a row is caught.
    enum Kind: String, CaseIterable, Sendable, Codable {
        case saved, serverAdopted, localUsed, queued, offline, conflict
        case trackFailed, streamFailed, loadFailed, downloadUnreadable, downloadUnreadableOffline
        case syncFailed, openFailed, cannotPlay, waitingForNetwork
    }

    var kind: Kind {
        switch self {
        case .saved: return .saved
        case .serverAdopted: return .serverAdopted
        case .localUsed: return .localUsed
        case .queued: return .queued
        case .offline: return .offline
        case .conflict: return .conflict
        case .trackFailed: return .trackFailed
        case .streamFailed: return .streamFailed
        case .loadFailed: return .loadFailed
        case .downloadUnreadable: return .downloadUnreadable
        case .downloadUnreadableOffline: return .downloadUnreadableOffline
        case .syncFailed: return .syncFailed
        case .openFailed: return .openFailed
        case .cannotPlay: return .cannotPlay
        case .waitingForNetwork: return .waitingForNetwork
        }
    }

    var label: String {
        switch self {
        case .saved: return String(localized: "Progress saved")
        case .serverAdopted: return String(localized: "Adopted server position")
        case .localUsed: return String(localized: "Using local position")
        case .queued: return String(localized: "Offline: queued for sync")
        case .offline: return String(localized: "Offline: progress saved locally")
        case .conflict: return String(localized: "Conflict detected")
        case .trackFailed: return String(localized: "Playback error: track unavailable")
        case .streamFailed: return String(localized: "Stream unavailable: the station could not be reached")
        case .loadFailed: return String(localized: "Could not load. Tap play to try again.")
        case .downloadUnreadable: return String(localized: "Download unreadable, playing from the server")
        case .downloadUnreadableOffline: return String(localized: "Download unreadable. Online it plays from the server.")
        case .syncFailed: return String(localized: "Progress is not being saved")
        case .openFailed(let sentence, _): return sentence
        case .cannotPlay(let sentence): return sentence
        case .waitingForNetwork: return String(localized: "Waiting for the network…")
        }
    }

    var icon: String {
        switch self {
        case .saved: return "checkmark.icloud"
        case .serverAdopted: return "arrow.down.circle"
        case .localUsed: return "internaldrive"
        case .queued: return "icloud.and.arrow.up"
        case .offline: return "icloud.slash"
        case .conflict: return "exclamationmark.triangle"
        case .trackFailed: return "exclamationmark.triangle"
        case .streamFailed: return "exclamationmark.triangle"
        case .loadFailed(let cause): return cause.icon
        case .downloadUnreadable: return "icloud.and.arrow.down"
        case .downloadUnreadableOffline: return "exclamationmark.triangle"
        case .syncFailed: return "exclamationmark.icloud"
        case .openFailed(_, let cause): return cause.icon
        case .cannotPlay: return "exclamationmark.triangle"
        case .waitingForNetwork: return "wifi.exclamationmark"
        }
    }
}

/// Why an item could not be loaded, as far as its error tells. Only a cause
/// that is surely the network gets the network symbol; a server, a file and
/// an error nobody can read get the warning triangle, because not knowing
/// is not the network.
nonisolated enum NoticeCause: String, Equatable, Sendable, Codable {
    case network
    case server
    case file
    case unknown

    var icon: String { self == .network ? "wifi.exclamationmark" : "exclamationmark.triangle" }

    /// URL loading codes that mean this device has no way out.
    private static let offlineCodes: Set<Int> = [
        NSURLErrorNotConnectedToInternet, NSURLErrorNetworkConnectionLost, NSURLErrorDataNotAllowed,
        NSURLErrorInternationalRoamingOff, NSURLErrorCannotFindHost, NSURLErrorDNSLookupFailed,
    ]
    /// URL loading codes AVFoundation sets when the host answered and
    /// refused (measured: 401 is -1013, 404 is -1100, 500 and 503 are
    /// -1008), or when nothing listens at a reachable address (-1004).
    private static let serverCodes: Set<Int> = [
        NSURLErrorUserAuthenticationRequired, NSURLErrorFileDoesNotExist, NSURLErrorResourceUnavailable,
        NSURLErrorBadServerResponse, NSURLErrorCannotConnectToHost, NSURLErrorUserCancelledAuthentication,
    ]
    /// The status AVFoundation puts under a local file it cannot find
    /// (measured: `AVFoundationErrorDomain -11800` over this code).
    private static let missingFileStatus = -17913

    /// The cause of a load failure. Without the network, it is the network,
    /// whatever the error says.
    static func of(_ error: Error?, online: Bool) -> NoticeCause {
        guard online else { return .network }
        guard let error = error as NSError? else { return .unknown }
        if error.domain == NSURLErrorDomain {
            if offlineCodes.contains(error.code) { return .network }
            if serverCodes.contains(error.code) { return .server }
            return .unknown
        }
        if error.domain == NSCocoaErrorDomain, (NSFileNoSuchFileError...NSFileReadUnknownError).contains(error.code) {
            return .file
        }
        let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError
        if error.domain == "AVFoundationErrorDomain", underlying?.code == missingFileStatus {
            return .file
        }
        return .unknown
    }
}

/// Which notice shows as the pill and for how long. Pure: the channel feeds
/// it the events and keeps the state.
nonisolated enum NoticeRule {
    struct Answer: Equatable, Sendable {
        /// Shows as the pill. Otherwise the notice only goes into the log.
        let pops: Bool
        /// Stays until the next start of playback, because it describes
        /// a state (playback stopped), not a moment.
        let holdsUntilPlay: Bool
        /// An error pushes any notice aside; an info pushes no error aside.
        let isError: Bool
    }

    static func answer(_ kind: PlaybackNotice.Kind) -> Answer {
        switch kind {
        case .saved, .queued, .offline:
            return Answer(pops: false, holdsUntilPlay: false, isError: false)
        case .serverAdopted, .localUsed:
            return Answer(pops: true, holdsUntilPlay: false, isError: false)
        case .conflict, .downloadUnreadable, .syncFailed, .openFailed:
            return Answer(pops: true, holdsUntilPlay: false, isError: true)
        case .trackFailed, .streamFailed, .loadFailed, .downloadUnreadableOffline, .cannotPlay:
            return Answer(pops: true, holdsUntilPlay: true, isError: true)
        case .waitingForNetwork:
            // It describes a state, the wait, so it holds; it is no error,
            // so it pushes no error aside. The stream running again ends it.
            return Answer(pops: true, holdsUntilPlay: true, isError: false)
        }
    }

    /// What the pill shows, and the stopping error kept behind it.
    struct State: Equatable, Sendable {
        var shown: PlaybackNotice?
        var held: PlaybackNotice?
    }

    enum Event: Equatable, Sendable {
        case show(PlaybackNotice)
        /// The short notice's time is up.
        case expired(PlaybackNotice)
        /// Playback started: a stopping error no longer describes the state.
        case played
        /// Another title took over: the old one's error is not its error.
        case titleChanged
        /// The stream delivers again, or the wait ended otherwise: the wait
        /// no longer describes the state; a stopping error stays.
        case streamResumed
    }

    static func next(_ state: State, _ event: Event) -> State {
        var state = state
        switch event {
        case .show(let notice):
            let incoming = answer(notice.kind)
            guard incoming.pops else { return state }
            if let shown = state.shown, answer(shown.kind).isError, !incoming.isError { return state }
            state.shown = notice
            if incoming.holdsUntilPlay { state.held = notice }
        case .expired(let notice):
            // A held error that is still valid comes back after a short
            // notice laid itself over it.
            guard state.shown == notice, !answer(notice.kind).holdsUntilPlay else { return state }
            state.shown = state.held
        case .played, .titleChanged:
            if let held = state.held, state.shown == held { state.shown = nil }
            state.held = nil
        case .streamResumed:
            guard state.held == .waitingForNetwork else { return state }
            if state.shown == .waitingForNetwork { state.shown = nil }
            state.held = nil
        }
        return state
    }
}

/// When a stalled stream says so. Pure: the channel asks it when its timer
/// fires, with how long the player has waited on the stream. A wait never
/// stops playback: AVFoundation fetches a stalled stream again by itself
/// (measured after about 60 s, then every 4 to 30 s) and plays on, and a
/// stop would turn that into a start by hand.
nonisolated enum StallRule {
    /// Waiting this long on the stream shows `waitingForNetwork`.
    static let hintAfterSeconds: Double = 5

    static func hints(waitedSeconds: Double, hintAfter: Double = hintAfterSeconds) -> Bool {
        waitedSeconds >= hintAfter
    }
}

/// One line of the notice log: the notice as it was said, when, and for
/// which title. Local only; nothing carries it to another device.
nonisolated struct NoticeLogEntry: Codable, Equatable, Sendable, Identifiable {
    let id: UUID
    let at: Double
    let kind: PlaybackNotice.Kind
    let label: String
    let icon: String
    let title: String?

    /// The log keeps at most `limit` lines and none older than `maxAge`
    /// seconds, newest last.
    static let limit = 200
    static let maxAge: Double = 7 * 24 * 3600

    static func trimmed(_ entries: [NoticeLogEntry], now: Double) -> [NoticeLogEntry] {
        Array(entries.filter { now - $0.at <= maxAge }.suffix(limit))
    }
}
