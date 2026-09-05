// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation

/// One episode of ours as far as matching a foreign state cares.
nonisolated struct ForeignMatchTarget: Sendable, Equatable {
    /// The store key, which is the episode's guid in this app.
    var id: String
    /// The guid as the feed carries it, without this app's prefix.
    var rawGUID: String?
    var enclosureURL: String
    var link: String?
    var title: String
    /// The key of the show this episode belongs to, as the caller
    /// computes it for feed addresses.
    var feedKey: String
}

/// The ladder from a foreign state to one of our episodes, the same for
/// every source: GUID, then the enclosure, then the twin bridge, then the
/// episode link, then an unambiguous title.
///
/// Pure. Each state climbs the ladder once and stops on the first rung
/// that names exactly one episode. A rung that names several tries to
/// settle them by the state's show; if that still leaves more than one,
/// the rung does not count and the next one is tried. Several states
/// landing on one episode are reduced to the one that speaks for it, so
/// the plan holds at most one match per episode whatever the file order.
nonisolated enum ForeignStateMatcher {
    enum Step: String, Sendable, CaseIterable {
        case guid, enclosure, twin, link, title
    }

    struct Match: Sendable, Equatable {
        var state: ForeignListeningState
        var targetID: String
        var step: Step
    }

    /// Why a state found no episode, as far as the ladder can tell.
    enum UnmatchedReason: String, Sendable, CaseIterable {
        /// The state names no show we have, or one without episodes here.
        case showUnknown
        /// The show is here, but no rung reached an episode of it.
        case notInFeed
        /// The source handed over neither guid, enclosure, link nor title.
        case noHandle
        /// Only a title was left and it was not unique on one side.
        case titleAmbiguous
    }

    struct Plan: Sendable, Equatable {
        var matches: [Match] = []
        var unmatched: [ForeignListeningState] = []
        /// One reason per `unmatched` entry, same order.
        var whyUnmatched: [UnmatchedReason] = []
    }

    /// `twinBridge` maps a normalized free enclosure onto the premium
    /// episode id the subscription step chose instead. `feedKeyOf` is the
    /// caller's one feed normalizer, so a state's show and a target's
    /// show compare on the same footing.
    static func plan(states: [ForeignListeningState],
                     targets: [ForeignMatchTarget],
                     twinBridge: [String: String] = [:],
                     feedKeyOf: (String) -> String) -> Plan {
        var byGUID: [String: [ForeignMatchTarget]] = [:]
        var byEnclosure: [String: [ForeignMatchTarget]] = [:]
        var byLink: [String: [ForeignMatchTarget]] = [:]
        var byTitle: [String: [ForeignMatchTarget]] = [:]
        var byID: [String: ForeignMatchTarget] = [:]
        var targetsByFeed: [String: Int] = [:]
        for target in targets {
            byID[target.id] = target
            targetsByFeed[target.feedKey, default: 0] += 1
            if let raw = target.rawGUID, !raw.isEmpty {
                byGUID[raw, default: []].append(target)
                // A permalink guid is also the link the source may carry.
                if raw.lowercased().hasPrefix("http") {
                    byLink[normalizeEnclosure(raw), default: []].append(target)
                }
            }
            byEnclosure[normalizeEnclosure(target.enclosureURL), default: []].append(target)
            if let link = target.link, !link.isEmpty {
                byLink[normalizeEnclosure(link), default: []].append(target)
            }
            byTitle[normalizeTitle(target.title), default: []].append(target)
        }
        // A title may only decide when the SOURCE carries it once as well;
        // two foreign states with the same title cannot both mean the one
        // episode of ours.
        var sourceTitleCounts: [String: Int] = [:]
        for state in states {
            if let title = state.episodeTitle { sourceTitleCounts[normalizeTitle(title), default: 0] += 1 }
        }

        var plan = Plan()
        for state in states {
            let feedKey = state.feedURL.map(feedKeyOf)
            func settle(_ candidates: [ForeignMatchTarget]?) -> ForeignMatchTarget? {
                guard let candidates, !candidates.isEmpty else { return nil }
                if candidates.count == 1 { return candidates[0] }
                guard let feedKey else { return nil }
                let inShow = candidates.filter { $0.feedKey == feedKey }
                return inShow.count == 1 ? inShow[0] : nil
            }
            var found: (ForeignMatchTarget, Step)?
            if let guid = state.episodeGUID, let hit = settle(byGUID[guid]) {
                found = (hit, .guid)
            } else if let enclosure = state.enclosureURL, let hit = settle(byEnclosure[normalizeEnclosure(enclosure)]) {
                found = (hit, .enclosure)
            } else if let enclosure = state.enclosureURL,
                      let bridged = twinBridge[normalizeEnclosure(enclosure)], let hit = byID[bridged] {
                found = (hit, .twin)
            } else if let link = state.episodeLink, let hit = settle(byLink[normalizeEnclosure(link)]) {
                found = (hit, .link)
            } else if let title = state.episodeTitle, sourceTitleCounts[normalizeTitle(title)] == 1,
                      let hit = settle(byTitle[normalizeTitle(title)]) {
                found = (hit, .title)
            }
            if let (target, step) = found {
                if let existing = plan.matches.firstIndex(where: { $0.targetID == target.id }) {
                    let kept = ForeignStateMerge.preferred(plan.matches[existing].state, state)
                    if kept == state { plan.matches[existing] = Match(state: state, targetID: target.id, step: step) }
                } else {
                    plan.matches.append(Match(state: state, targetID: target.id, step: step))
                }
            } else {
                plan.unmatched.append(state)
                plan.whyUnmatched.append(reason(for: state, feedKey: feedKey,
                                                targetsInShow: feedKey.map { targetsByFeed[$0] ?? 0 } ?? 0,
                                                sourceTitleCounts: sourceTitleCounts, byTitle: byTitle))
            }
        }
        return plan
    }

    /// The reason a state stayed unmatched, in the order the ladder would
    /// have needed them: a show we have, a handle to match on, a unique
    /// title. Named for the preview and the per-show log line.
    private static func reason(for state: ForeignListeningState, feedKey: String?, targetsInShow: Int,
                               sourceTitleCounts: [String: Int],
                               byTitle: [String: [ForeignMatchTarget]]) -> UnmatchedReason {
        if feedKey == nil || targetsInShow == 0 { return .showUnknown }
        let hasHandle = [state.episodeGUID, state.enclosureURL, state.episodeLink, state.episodeTitle]
            .contains { !($0 ?? "").isEmpty }
        if !hasHandle { return .noHandle }
        if let title = state.episodeTitle {
            let key = normalizeTitle(title)
            if (sourceTitleCounts[key] ?? 0) > 1 || (byTitle[key]?.count ?? 0) > 1 { return .titleAmbiguous }
        }
        return .notInFeed
    }

    /// Make enclosure and link addresses comparable: drop query and
    /// scheme, lowercase, trim trailing slashes. CDN tokens and http/https
    /// variants of one file collapse together.
    static func normalizeEnclosure(_ raw: String) -> String {
        var s = raw.lowercased()
        if let q = s.firstIndex(of: "?") { s = String(s[..<q]) }
        s = s.replacingOccurrences(of: "https://", with: "")
             .replacingOccurrences(of: "http://", with: "")
        while s.hasSuffix("/") { s.removeLast() }
        return s
    }

    static func normalizeTitle(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// The guid as the feed carries it. This app stores episodes under
    /// `rss:<feed key>:<guid>`; anything without that shape is returned
    /// unchanged.
    static func rawGUID(storedGUID: String) -> String {
        let parts = storedGUID.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0] == "rss" else { return storedGUID }
        return String(parts[2])
    }
}

/// What a foreign library holds, counted for the preview before anything
/// is applied. Pure, so the surface shows measured numbers.
nonisolated struct ForeignImportPreview: Sendable, Equatable {
    var shows = 0
    var alreadySubscribed = 0
    var states = 0
    var finished = 0
    var inProgress = 0
    var withMoment = 0
    var unimportablePaid = 0

    /// The shared key-value store holds one megabyte for everything, and a
    /// refused write is silent. Measured on a real pot: 2621 states took
    /// 324 580 bytes, about 124 per state, so an import can say before it
    /// runs roughly how much of the pot it will take.
    static let bytesPerState = 124
    /// A subscription statement in the choices blob: key with the feed key,
    /// the feed address as value, a stamp. Measured on the plist form.
    static let bytesPerSubscription = 180
    static let potLimitBytes = 1_000_000

    /// Rough bytes the imported states and subscriptions will occupy in
    /// the pot; the subscriptions travel since they became a choice family.
    var estimatedPotBytes: Int { states * Self.bytesPerState + shows * Self.bytesPerSubscription }

    /// `subscribedFeedKeys` are the keys of the shows this device already
    /// follows, computed with the same `feedKeyOf` the caller passes.
    static func make(_ library: ForeignLibrary, subscribedFeedKeys: Set<String>,
                     feedKeyOf: (String) -> String) -> ForeignImportPreview {
        var preview = ForeignImportPreview()
        preview.shows = library.feedURLs.count
        preview.alreadySubscribed = library.feedURLs.filter { subscribedFeedKeys.contains(feedKeyOf($0)) }.count
        preview.states = library.states.count
        preview.finished = library.states.filter(\.finished).count
        preview.inProgress = library.states.filter { !$0.finished && $0.position > 0 }.count
        preview.withMoment = library.states.filter { $0.stampedAt != nil }.count
        preview.unimportablePaid = library.unimportablePaidCount
        return preview
    }
}
