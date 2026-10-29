// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation

/// Whether a host stopped answering the downloads asked of it.
///
/// The background session asks a host that accepts and never answers, or
/// closes without an answer, again and again until its resource limit, and
/// tells the app nothing meanwhile. A queued task and an asking one look
/// the same from the app (no bytes, no answer), and the session runs at
/// most six tasks per host, so the rule watches a HOST, not a task: any
/// byte from any of its tasks keeps it alive, and a task queued behind
/// living ones never ends here. A host is named by the address the app
/// asked, so a redirect to another host still counts where it was asked.
///
/// The app has to see the silence itself: the session keeps loading while
/// the app is suspended, without calling back. A tick after a gap longer
/// than `maxGap`, or one without a network, starts every clock again.
nonisolated struct DownloadSilence: Equatable, Sendable {
    /// How long a host may give no byte before its downloads end.
    let limit: TimeInterval
    /// The longest gap between two ticks that still counts as watched.
    let maxGap: TimeInterval

    /// Per host with downloads running: since when it is silent.
    private(set) var since: [String: Date] = [:]
    private(set) var lastTick: Date?

    init(limit: TimeInterval, maxGap: TimeInterval) {
        self.limit = limit
        self.maxGap = maxGap
    }

    /// A download to `host` started; an already watched host keeps its clock.
    mutating func began(_ host: String, at now: Date) {
        if since[host] == nil { since[host] = now }
    }

    /// A byte came from `host`.
    mutating func heard(_ host: String, at now: Date) {
        since[host] = now
    }

    /// No download to `host` runs any more.
    mutating func left(_ host: String) {
        since[host] = nil
    }

    /// One look at the clock: the hosts silent for `limit` while the app
    /// watched without a break and the device was online.
    mutating func tick(at now: Date, online: Bool) -> [String] {
        defer { lastTick = now }
        let watched = lastTick.map { now.timeIntervalSince($0) <= maxGap } ?? false
        guard online, watched else {
            for host in since.keys { since[host] = now }
            return []
        }
        return since.filter { now.timeIntervalSince($0.value) >= limit }.map(\.key).sorted()
    }
}
