// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation

/// Carrying the state of one Mär Sync identity onto another that may
/// already hold state (a device restored from a backup holds the backup's
/// state under the fingerprint): nothing that has not gone out is lost.
nonisolated enum IdentityCarry {
    struct Side: Equatable, Sendable {
        var stands: [String: [Double]] = [:]
        var standsVersion: String? = nil
        var queue: [String: [Double]] = [:]
        var removals: Set<String> = []
        var playlistsPending: Data? = nil
        var choicesPending: Data? = nil
    }

    /// The queues join, the newer moment (second value) winning per title,
    /// the source on a tie. The picture of what the service holds is the
    /// source's whole when it has read (its version stands), else the
    /// target's whole; never mixed per entry, or a title the service no
    /// longer holds would come back. The removals are the source's alone:
    /// they carry no moment, and an old one would delete a title made again
    /// elsewhere. A pending document is the source's when it has one, else
    /// the target's; a target's that gives way is named in `dropped`.
    enum Living: Equatable, Sendable { case source, target, tie }

    static func living(source: Side, target: Side) -> Living { .source }

    static func merged(source: Side, target: Side, living: Living) -> (side: Side, dropped: [String]) {
        var out = Side()
        if source.standsVersion != nil {
            out.stands = source.stands
            out.standsVersion = source.standsVersion
        } else {
            out.stands = target.stands
            out.standsVersion = target.standsVersion
        }
        out.queue = target.queue.merging(source.queue) { older, newer in
            (newer.count > 1 ? newer[1] : 0) >= (older.count > 1 ? older[1] : 0) ? newer : older
        }
        out.removals = source.removals
        var dropped: [String] = []
        out.playlistsPending = source.playlistsPending ?? target.playlistsPending
        if source.playlistsPending != nil, target.playlistsPending != nil { dropped.append("playlists") }
        out.choicesPending = source.choicesPending ?? target.choicesPending
        if source.choicesPending != nil, target.choicesPending != nil { dropped.append("choices") }
        return (out, dropped)
    }
}
