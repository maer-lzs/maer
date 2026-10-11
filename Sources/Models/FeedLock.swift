// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation

/// Which lock a feed's artwork carries: none, the premium lock, or the
/// warning of a lastingly refused access. One value instead of two flags,
/// so no surface can show the premium lock and forget the refusal: every
/// surface asks `PodcastSubscriptions.lock(feedURL:)` and hands the answer on.
nonisolated enum FeedLock: Equatable, Sendable {
    case none
    case premium
    case refused

    /// The lock of a feed, pure: a lasting refusal is the stronger fact and
    /// wins over premium.
    static func of(isPremium: Bool, isRefused: Bool) -> FeedLock {
        if isRefused { return .refused }
        return isPremium ? .premium : .none
    }
}
