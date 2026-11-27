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

    /// Which side lives: at a reload the caller knows (the source has just
    /// read); at a cold start nobody does, and `living(source:target:)`
    /// estimates it.
    enum Living: Equatable, Sendable { case source, target, tie }

    /// The side with the newest moment over its picture and its queue
    /// lives; an empty side does not; equal moments are a tie. A moment is
    /// when something was heard, not when it was read, so this is only
    /// asked where nobody knows.
    static func living(source: Side, target: Side) -> Living {
        func newest(_ side: Side) -> Double? {
            (Array(side.stands.values) + Array(side.queue.values)).compactMap { $0.count > 1 ? $0[1] : nil }.max()
        }
        switch (newest(source), newest(target)) {
        case (nil, nil): return .tie
        case (_, nil): return .source
        case (nil, _): return .target
        case let (s?, t?): return s == t ? .tie : (s > t ? .source : .target)
        }
    }

    /// From the living side whole: the picture with its version, the
    /// removals, a pending document (the other's when the living has none;
    /// one of the other that gives way is named). The queues always join,
    /// the newer moment winning per title, the source on a tie. A tie keeps
    /// the target (the identity the device runs under) and applies the
    /// removals of neither side: a fallen removal lets a title come back,
    /// an old one applied deletes it; the first error is the smaller.
    typealias PendingMerge = @Sendable (_ kind: String, _ live: Data, _ other: Data) -> Data?

    static func merged(source: Side, target: Side, living: Living,
                       mergePending: PendingMerge? = nil) -> (side: Side, dropped: [String]) {
        let live = living == .source ? source : target
        let other = living == .source ? target : source
        var out = Side()
        out.stands = live.stands
        out.standsVersion = live.standsVersion
        out.queue = target.queue.merging(source.queue) { older, newer in
            (newer.count > 1 ? newer[1] : 0) >= (older.count > 1 ? older[1] : 0) ? newer : older
        }
        var dropped: [String] = []
        if living == .tie {
            out.removals = []
            if !source.removals.isEmpty || !target.removals.isEmpty { dropped.append("removals") }
        } else {
            out.removals = live.removals
            if !other.removals.isEmpty { dropped.append("removals") }
        }
        out.playlistsPending = live.playlistsPending ?? other.playlistsPending
        if live.playlistsPending != nil, other.playlistsPending != nil { dropped.append("playlists") }
        out.choicesPending = live.choicesPending ?? other.choicesPending
        if live.choicesPending != nil, other.choicesPending != nil { dropped.append("choices") }
        return (out, dropped)
    }
}
