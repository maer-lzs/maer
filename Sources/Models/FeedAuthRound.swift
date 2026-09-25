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
        /// What this device should put up as its own block. Nil exactly
        /// when `hold` names a reason.
        let putUp: [String: FeedAuthBlock.Entry]?
        /// What the page says.
        let block: FeedAuthStanding.Block
        /// Why nothing goes up, or nil when it does.
        let hold: Hold?
    }

    /// The reasons to hold the own block back, each with the words the log
    /// line uses. One line said "the code is not this account's" for a
    /// newer format too, which is a different fact with a different remedy.
    enum Hold: Equatable {
        /// The other devices' blocks were not listed yet in this session. An
        /// empty store before the first listing is not an empty account:
        /// measured, a device wrote its block 4 ms after signing in, before
        /// it had seen a single foreign one.
        case notListedYet
        /// Blocks exist and none opens with this device's code.
        case sealedForAnother
        /// A newer build wrote a format this one cannot read.
        case newerFormat(Int)

        var logReason: String {
            switch self {
            case .notListedYet: return "the other devices' blocks are not listed yet"
            case .sealedForAnother: return "the code is not this account's"
            case .newerFormat(let version): return "a newer build wrote format \(version)"
            }
        }
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
    ///   - listed: whether the other devices' blocks were listed at least
    ///     once in this session. Before that, `theirs` and `openings` say
    ///     nothing, and nothing goes up.
    static func plan(mine: [String: FeedAuthBlock.Entry],
                     theirs: [[String: FeedAuthBlock.Entry]],
                     openings: [FeedAuthBlock.Opening],
                     listed: Bool) -> Plan {
        let block = FeedAuthStanding.block(fromForeign: openings)
        var incoming: [String: FeedAuthBlock.Entry] = [:]
        for side in theirs { incoming = FeedAuthMerge.union(local: incoming, remote: side) }
        let merged = FeedAuthMerge.union(local: mine, remote: incoming)
        let apply = FeedAuthMerge.differs(merged, from: mine) ? merged : nil
        // Holding back is about the OWN block only. Whatever arrived and
        // could be read is still worth keeping: a credential that opened is
        // one this account owns, whatever the rest of the far side looks
        // like.
        //
        // **What goes up is the UNION, not this device's own stock, and the
        // reason is retirement.** A phone that is sold, lost or wiped takes
        // its document with it; if each device only ever published what it
        // personally held, the credentials that lived on that one device
        // would go with it even though another device had already read
        // them. Publishing the union means every device that ever saw a
        // credential keeps it alive for the others.
        //
        // **The price, measured and not estimated:** the union lies on the
        // service once PER DEVICE. A key is at most 16 characters (an FNV
        // hash of the normalised feed address), so one feed costs about 106
        // bytes and 25 feeds seal to about 3.7 kB. Ten devices carrying that
        // union is 36 kB, which is 0.05 percent of the service's 64 MiB body
        // limit. A witness holds the number so it cannot drift silently.
        //
        // The same union on the 1 MB key-value store would be a budget
        // question, and that is exactly the channel this class is leaving.
        let hold = listed ? hold(for: block) : .notListedYet
        return Plan(apply: apply, putUp: hold == nil ? merged : nil, block: block, hold: hold)
    }

    /// The hold a far side asks for, following `FeedAuthStanding.mayWrite`.
    static func hold(for block: FeedAuthStanding.Block) -> Hold? {
        guard !FeedAuthStanding.mayWrite(block) else { return nil }
        switch block {
        case .newerFormat(let version): return .newerFormat(version)
        case .none, .opens, .sealedForAnother: return .sealedForAnother
        }
    }
}
