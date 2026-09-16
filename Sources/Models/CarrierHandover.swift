// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation

/// What a carrier handover is, before anything is carried.
///
/// Switching the sync service on or off changes WHO carries, and nothing
/// today brings the state across: the way IN exists, the way OUT does not.
/// So a handover writes this device's whole state to the new carrier once.
/// **The device holds everything anyway**, which is why one mechanism
/// serves all three cases: service to Apple, Apple to service, and a second
/// device set up fresh. Whoever builds three ways for that has missed it.
///
/// This type decides the two things that can make a handover fail, and it
/// decides them BEFORE anything is written:
///
/// 1. **Does it fit?** The key-value store holds one megabyte for
///    everything together, and a refused write there is silent. A handover
///    that fails quietly at the people with the most to lose is not a
///    handover.
/// 2. **What will it cost?** Not a number of items, a number of WRITES, and
///    the two directions are not the same size at all.
nonisolated enum CarrierHandover {
    /// The families that travel. **The claim is not among them**, and that
    /// is not an omission: it says which device is playing right now, it
    /// ages out by itself within its cadence, and carrying a stale one
    /// across would announce a device that stopped.
    enum Family: String, CaseIterable, Equatable {
        case stands, playlists, choices, stats, feedAuth
    }

    /// What the far side is, as far as the cost is concerned.
    enum Target: Equatable {
        /// The Mär sync service: whole documents, one write each.
        case service
        /// Apple: the pot travels as one record PER ITEM, in batches, and
        /// the key-value store below it has the one megabyte.
        case apple(hasRoomLimit: Bool)
    }

    /// Bytes per kind, measured on a real pot and already carried by
    /// `ForeignStateMatcher`; named here again so this rule does not invent
    /// a second set of numbers for the same thing.
    static let bytesPerState = ForeignImportPreview.bytesPerState
    static let bytesPerSubscription = ForeignImportPreview.bytesPerSubscription
    static let potLimitBytes = ForeignImportPreview.potLimitBytes

    /// CloudKit refuses more than this many records in one modify, so the
    /// pot goes up in batches and the person watches batches, not percent.
    static let recordsPerBatch = 400

    /// Whether the state fits at the far side, and what to say when it does
    /// not.
    enum Room: Equatable {
        /// No ceiling applies, or the state is far enough below it.
        case fits
        /// It would not fit, and this is what it would need against what it
        /// has. **Refusing loudly is the entire point**: the store answers a
        /// write it will not take with silence, so a handover that simply
        /// tried would look like it worked.
        case tooLarge(needs: Int, limit: Int)
    }

    static func room(states: Int, subscriptions: Int, target: Target) -> Room {
        guard case .apple(let hasRoomLimit) = target, hasRoomLimit else { return .fits }
        let needs = states * bytesPerState + subscriptions * bytesPerSubscription
        return needs <= potLimitBytes ? .fits : .tooLarge(needs: needs, limit: potLimitBytes)
    }

    /// How many writes a handover takes, which is what the person is made
    /// to wait for.
    ///
    /// **The two directions are not the same size**, and the difference is
    /// the reason this is a function and not a constant: to the service a
    /// whole document is ONE write, so the handover is about half a dozen.
    /// To Apple the pot is one record per item in batches of 400, so at
    /// eight thousand items it is twenty batches on top of the rest.
    /// Showing a share of the cheap direction would make the expensive one
    /// look broken.
    static func writes(states: Int, target: Target) -> Int {
        switch target {
        case .service:
            return Family.allCases.count
        case .apple:
            let potBatches = max(1, Int((Double(states) / Double(recordsPerBatch)).rounded(.up)))
            return potBatches + (Family.allCases.count - 1)
        }
    }

    /// Whether this handover is the one worth showing progress for.
    /// Anything that is over in a handful of writes needs a spinner, not a
    /// count; anything that takes batches needs to say which batch.
    static func showsBatches(states: Int, target: Target) -> Bool {
        writes(states: states, target: target) > Family.allCases.count
    }
}
