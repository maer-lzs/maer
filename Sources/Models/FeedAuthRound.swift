// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation

/// What one round of carrying the feed credentials decides, as a pure
/// function.
///
/// The runner around it opens envelopes and talks to the keychain and the
/// service; it decides nothing. Every choice that could lose a credential
/// lives here, where a test can reach it without a device, without a
/// network and without a key.
nonisolated enum FeedAuthRound {
    struct Plan: Equatable {
        /// What this device should hold afterwards. Nil when it already
        /// holds exactly that, so a round that changes nothing writes
        /// nothing.
        let apply: [String: FeedAuthBlock.Entry]?
        /// What this device should put up as its own block. Nil means hold
        /// back, and the only reason to hold back is a code that does not
        /// belong to this account.
        let putUp: [String: FeedAuthBlock.Entry]?
        /// What the page says.
        let block: FeedAuthStanding.Block
    }

    /// - Parameters:
    ///   - mine: what this device holds, with moments.
    ///   - theirs: the other devices' blocks, already opened and decoded.
    ///     One element per block this device could read.
    ///   - openings: what came out of EVERY other device's block, including
    ///     the ones that did not open. This is what decides whether this
    ///     device's code belongs here, so it must carry the failures too;
    ///     passing only the successes would make a wrong code look like an
    ///     empty account.
    static func plan(mine: [String: FeedAuthBlock.Entry],
                     theirs: [[String: FeedAuthBlock.Entry]],
                     openings: [FeedAuthBlock.Opening]) -> Plan {
        let block = FeedAuthStanding.block(fromForeign: openings)
        var incoming: [String: FeedAuthBlock.Entry] = [:]
        for side in theirs { incoming = FeedAuthMerge.union(local: incoming, remote: side) }
        let merged = FeedAuthMerge.union(local: mine, remote: incoming)
        let apply = FeedAuthMerge.differs(merged, from: mine) ? merged : nil
        // Holding back is about the OWN block only. Whatever arrived and
        // could be read is still worth keeping: a credential that opened is
        // one this account owns, whatever the rest of the far side looks
        // like.
        let putUp = FeedAuthStanding.mayWrite(block) ? merged : nil
        return Plan(apply: apply, putUp: putUp, block: block)
    }
}
