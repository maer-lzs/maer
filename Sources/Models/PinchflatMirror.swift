// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation

/// Pinchflat Paket A (a7fa35e Nachschärfung): the server is the SOURCE OF
/// TRUTH for the group — the OPML list is MIRRORED, not imported. Connect =
/// done; new channels appear on refresh by themselves; a channel deleted in
/// Pinchflat leaves the group (progress stays, like any unsubscribe). Hiding
/// a channel is the OPT-OUT exception and survives mirror runs.
///
/// Pure and fixture-tested: the diff is where a silent mistake would eat a
/// user's subscriptions, so it computes without side effects.
nonisolated enum PinchflatMirror {
    struct Diff: Equatable {
        /// Server channels not yet in the group (and not hidden) — subscribe.
        var toSubscribe: [String] = []
        /// Group members the server no longer lists — unsubscribe (progress
        /// stays; the row simply leaves the group).
        var toUnsubscribe: [String] = []
    }

    /// `serverFeeds`: xmlUrls from the OPML. `mirrored`: feed URLs currently
    /// carrying this server's origin. `hidden`: the user's opt-outs (persist
    /// across runs — a hidden channel is NEVER re-subscribed).
    static func diff(serverFeeds: [String], mirrored: Set<String>,
                     hidden: Set<String>) -> Diff {
        let server = Set(serverFeeds)
        var result = Diff()
        result.toSubscribe = serverFeeds.filter { !mirrored.contains($0) && !hidden.contains($0) }
        result.toUnsubscribe = mirrored.subtracting(server).sorted()
        return result
    }

    /// The origin tag a mirrored feed carries (host-scoped, so two Pinchflat
    /// servers stay two groups).
    static func originTag(host: String) -> String { "pinchflat:\(host)" }
}
