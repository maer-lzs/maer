// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation

/// A foreign claim on a LIBRARY item (a book on the server, a server
/// podcast episode) means the other device is listening to something whose
/// stand lives on the server, not in the pot. The receiver's rows only see
/// that stand after a progress refresh, which used to run when the scene
/// became active. This gate admits one refresh per claimed item, then one
/// every `interval` at most, so the ten-second heartbeat never turns into a
/// server round trip per beat.
nonisolated struct ClaimRefreshThrottle: Sendable {
    /// Minimum distance between two refreshes for the same item, in ms.
    var intervalMs: Double = 60_000
    private var lastRefreshMs: [String: Double] = [:]

    init(intervalMs: Double = 60_000) {
        self.intervalMs = intervalMs
    }

    /// Whether a refresh for this item may run now. Records the moment when
    /// it does.
    mutating func admits(itemId: String, nowMs: Double) -> Bool {
        if let last = lastRefreshMs[itemId], nowMs - last < intervalMs { return false }
        lastRefreshMs[itemId] = nowMs
        return true
    }

    /// Which library the claimed item belongs to, or nil when its stand
    /// travels another way (the pot, or not at all).
    enum Library: Equatable, Sendable { case books, serverPodcasts }

    /// A refresh is worth it only for items whose stand the server holds:
    /// a bare Audiobookshelf id (a book) or a server podcast episode. Pot
    /// items (rss, catalogue, local) reach the rows through the pot, radio
    /// has no stand, and server music travels by the claim alone.
    static func library(of itemId: String) -> Library? {
        switch MediaFamily.of(itemId) {
        case .book: return itemId.hasPrefix("local:") ? nil : .books
        case .podcast: return itemId.hasPrefix("abspod:") ? .serverPodcasts : nil
        default: return nil
        }
    }
}
