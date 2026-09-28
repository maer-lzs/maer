// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation

/// Whether the changes socket still carries, told without a clock of its
/// own. A socket that the platform calls open can be dead: a changed network
/// path, a half-open line on a dying network. Neither side pings, so the
/// only proof is traffic that happens anyway. The service announces every
/// write of an owner to every socket of that owner, the writer's own
/// included, so a write this device made is followed by its own echo. An
/// echo that does not come within the window says the socket is silent.
nonisolated enum MaerSyncLiveness {
    /// How long an echo may take. The service announces when it stores, so
    /// the echo usually arrives before the write's answer; the window is
    /// the margin for a slow line, not the expected time.
    static let echoWindow: Double = 10

    /// Why the app dropped the socket, as the log line names it; `closed`
    /// is an end that came from outside.
    enum Cause: String, Sendable {
        case path, stale, timeout, closed
    }

    /// An echo this device waits for: a version of a document the socket
    /// announces, and when the waiting began (seconds).
    struct Awaited: Equatable, Sendable {
        let kind: String
        let scope: String
        let version: String
        let since: Double

        init(kind: String, scope: String, version: String, since: Double) {
            self.kind = kind
            self.scope = scope
            self.version = version
            self.since = since
        }

        var key: String { MaerSyncLiveness.key(kind: kind, scope: scope) }
    }

    static func key(kind: String, scope: String) -> String { "\(kind)|\(scope)" }

    /// Silent: an awaited echo is older than the window.
    static func isSilent(_ awaited: [Awaited], now: Double, window: Double = echoWindow) -> Bool {
        awaited.contains { now - $0.since >= window }
    }

    /// Whether an echo is to be waited for at all: only for a kind the socket
    /// announces, and not when the announcement came before the answer.
    static func awaits(kind: String, version: String, announcedKinds: Set<String>,
                       alreadyAnnounced: String?) -> Bool {
        announcedKinds.contains(kind) && alreadyAnnounced != version
    }

    /// A failure that says the LINE may be gone, not the service: the socket
    /// that rode on the same line is then no proof of anything any more.
    static func isLineLoss(_ error: Error) -> Bool {
        guard let url = error as? URLError else { return false }
        return [.timedOut, .networkConnectionLost, .notConnectedToInternet,
                .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed].contains(url.code)
    }
}

/// The device's network path as the sync reads it: whether it carries at
/// all, and which kinds of interface it offers (a tunnel shows up as its own
/// kind and comes and goes with a VPN).
nonisolated struct MaerSyncPath: Hashable, Sendable {
    let satisfied: Bool
    let interfaces: Set<String>

    init(satisfied: Bool, interfaces: Set<String>) {
        self.satisfied = satisfied
        self.interfaces = interfaces
    }

    /// For the log line: status and kinds, never an address.
    var line: String { "\(satisfied ? "satisfied" : "unsatisfied")|\(interfaces.sorted().joined(separator: ","))" }
}

/// When the socket may be opened again after opens that failed: after n
/// failures in a row the next try waits 2 s times 2 to the n minus one, at
/// most 120 s. An occasion before that does not open. A dying network is
/// asked less and less often instead of at every tick.
nonisolated enum MaerSyncReopen {
    static let firstWait: Double = 2
    static let longestWait: Double = 120

    static func wait(afterFailures failures: Int) -> Double {
        guard failures > 0 else { return 0 }
        return min(longestWait, firstWait * pow(2, Double(failures - 1)))
    }

    static func mayOpen(failures: Int, lastAttempt: Double?, now: Double) -> Bool {
        guard let lastAttempt else { return true }
        return now - lastAttempt >= wait(afterFailures: failures)
    }

    /// Whether a new path lifts the wait after failed opens: only a path
    /// that carries, and on which no open failed since the last one that
    /// stood. A flapping path (a tunnel that comes and goes, a cell edge)
    /// swings between paths it has already failed on, and each swing used
    /// to start the count at nought again.
    static func pathLiftsTheWait(_ new: MaerSyncPath, failedOn: Set<MaerSyncPath>) -> Bool {
        new.satisfied && !failedOn.contains(new)
    }
}
