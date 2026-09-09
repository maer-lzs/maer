// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation

/// An unsubscribe made while the iCloud sync was OFF, kept until it can be
/// said out loud.
///
/// Why this exists, measured: for most families the reconcile treats a stamp
/// without a local value as a tombstone and lets it travel. Subscriptions are
/// deliberately excluded from that derivation, and the reason is good: „not in
/// the store" also means „not adopted yet" or „the feed failed to load", so a
/// DERIVED tombstone would bury the other device's subscription for the whole
/// account. A subscription tombstone therefore comes from the person's own
/// unsubscribe only.
///
/// That leaves one hole. With the sync switched off, `note` stores the event
/// TIME and nothing else, because every other family can rebuild its statement
/// from local state. Subscriptions cannot, by the decision above. So the
/// unsubscribe was forgotten, and the next adoption brought the show back.
///
/// The answer is not to derive it after all. It is to RECORD it: the danger in
/// the comment above comes from guessing, not from remembering. What is
/// remembered here is exactly what the person did, with the moment they did
/// it, so the ordinary newest-wins merge can settle it against any statement
/// another device made.
nonisolated enum SubscriptionRemovalRecord {
    /// The removals that still have something to say.
    ///
    /// A feed that is subscribed again drops out, and that is the whole
    /// safety of this store: the record is a statement about the past, and a
    /// later subscribe is a newer statement about the same feed. Without this
    /// filter a re-subscribe made while the sync was off would be undone by
    /// its own predecessor the moment the switch went on.
    static func pending(recorded: [String: Double],
                        subscribedKeys: Set<String>) -> [String: Double] {
        recorded.filter { !subscribedKeys.contains($0.key) }
    }

    /// What may be forgotten after a reconcile: everything the cloud now
    /// carries as a removal that is at least as new as the record.
    ///
    /// „At least as new" and not „equal": another device may have removed the
    /// same feed later, and then its statement says the same thing with a
    /// better time. Keeping the older record would make this device re-state
    /// the removal on every reconcile forever.
    static func settled(recorded: [String: Double],
                        cloudRemovalTimes: [String: Double]) -> Set<String> {
        Set(recorded.compactMap { key, t in
            guard let cloudT = cloudRemovalTimes[key], cloudT >= t else { return nil }
            return key
        })
    }
}
