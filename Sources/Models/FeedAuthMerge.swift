// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation

/// How two sides of the feed credentials come together.
///
/// Pure, and the rule is deliberately the cautious one: **a deletion does
/// NOT travel in format 1.** Everywhere else in Mär a removal is a statement
/// that travels as a tombstone, and that is right for a station or a
/// subscription. Here the cost of the two mistakes is not symmetric: a
/// credential that lingers on a second device is a stale password that
/// fails once and is overwritten by the next edit, while a credential that
/// vanishes locks the person out of a feed they PAID for and that they may
/// never have seen, because the provider put it into the feed address.
///
/// So the union keeps both sides, and a later format can add tombstones with
/// a moment, once there is a measured case that needs them.
nonisolated enum FeedAuthMerge {
    /// Per feed the NEWER write wins, and everything either side knows
    /// survives.
    ///
    /// An unstamped entry loses against any stamped one, and that is the
    /// right way round: the stamped one was written by a build that knew
    /// about travel, so it is at least as new as the other by construction.
    /// Two equal moments keep the LOCAL side, because the tie is honest and
    /// the local side is the one the person is looking at.
    static func union(local: [String: FeedAuthBlock.Entry],
                      remote: [String: FeedAuthBlock.Entry]) -> [String: FeedAuthBlock.Entry] {
        var out = local
        for (key, incoming) in remote {
            guard let mine = out[key] else { out[key] = incoming; continue }
            if incoming.at > mine.at { out[key] = incoming }
        }
        return out
    }

    /// Whether the merged state differs from what this device already holds.
    /// Used to decide whether a write is worth its round trip; comparing the
    /// CREDENTIALS, not the moments, so a re-stamp alone never causes
    /// traffic.
    static func differs(_ merged: [String: FeedAuthBlock.Entry],
                        from local: [String: FeedAuthBlock.Entry]) -> Bool {
        guard merged.count == local.count else { return true }
        for (key, value) in merged {
            guard let mine = local[key],
                  mine.credentials == value.credentials else { return true }
        }
        return false
    }
}
