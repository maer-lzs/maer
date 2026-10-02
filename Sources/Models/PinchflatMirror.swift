// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation

/// The server is the SOURCE OF TRUTH for the group. The OPML list is
/// MIRRORED, not imported. Connect =
/// done; new channels appear on refresh by themselves; a channel deleted in
/// Pinchflat leaves the group (progress stays, like any unsubscribe). Hiding
/// a channel is the OPT-OUT exception and survives mirror runs.
///
/// Pure and fixture-tested: the diff is where a silent mistake would eat a
/// user's subscriptions, so it computes without side effects.
nonisolated enum PinchflatMirror {
    struct Diff: Equatable {
        /// Server channels not yet in the group (and not hidden). Subscribe.
        var toSubscribe: [String] = []
        /// Group members the server no longer lists. Unsubscribe (progress
        /// stays; the row simply leaves the group).
        var toUnsubscribe: [String] = []
    }

    /// `serverFeeds`: xmlUrls from the OPML. `mirrored`: feed URLs currently
    /// carrying this server's origin. `hidden`: the user's opt-outs (persist
    /// across runs. A hidden channel is NEVER re-subscribed).
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

    /// What a re-admit of a hidden channel came to after the mirror ran:
    /// the channel is a member of the group again, or it is not, and then
    /// the reason is the switch or the server's list. The question is the
    /// MEMBERSHIP of this one channel, never the size of the group: a group
    /// with any other channel standing answered "joined" for a channel the
    /// server had long deleted.
    enum ReadmitOutcome: Equatable {
        case joined
        /// The source's OWN switch on the podcast source page.
        case switchedOff
        /// The switch is on and the source is still not live, because the
        /// podcast area it feeds is off. **Its own case, because the value
        /// that decides is COMPOSED** (`podcastsTab && pinchflatEnabled`):
        /// one sentence for both told people their switched-on switch was
        /// off. Here the second part is known by name, so it is said.
        case areaOff
        /// No server is set up, so no list was asked: the mirror returns
        /// without a request, and "the server no longer lists it" would
        /// name a list nobody read.
        case noServer
        case notListed
    }

    /// `sourceOn` is the switch on the page, `active` the composed answer
    /// the mirror hangs on. Only their difference tells the two apart, and
    /// only the one that really holds may be named. `serverKnown` says
    /// whether a server is set up at all.
    static func readmitOutcome(sourceOn: Bool, active: Bool, serverKnown: Bool, member: Bool) -> ReadmitOutcome {
        guard sourceOn else { return .switchedOff }
        guard active else { return .areaOff }
        guard serverKnown else { return .noServer }
        return member ? .joined : .notListed
    }
}
