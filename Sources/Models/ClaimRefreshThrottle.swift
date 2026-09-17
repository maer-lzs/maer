// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation

/// A foreign claim on a LIBRARY item (a book on the server, a server
/// podcast episode) means the other device is listening to something whose
/// stand lives on the server, not in the pot. The receiver's rows only see
/// that stand after a progress refresh, which used to run when the scene
/// became active. This gate admits one refresh per claimed item, a second
/// pass once `secondPassMs` have passed (the other device's push runs over
/// the same round trip as the first refresh, so the first pass may read
/// the stand from before it; the heartbeats every ten seconds bring the
/// claim that runs the second, no timer needed), then one every
/// `intervalMs` at most, so the heartbeat never turns into a server round
/// trip per beat.
nonisolated struct ClaimRefreshThrottle: Sendable {
    /// Minimum distance between two refreshes for the same item, in ms.
    var intervalMs: Double = 60_000
    /// Distance from the first pass to the second, in ms.
    var secondPassMs: Double = 15_000
    private var lastRefreshMs: [String: Double] = [:]
    /// Items whose second pass is still owed, with the moment of the first.
    private var secondPassDue: [String: Double] = [:]

    init(intervalMs: Double = 60_000, secondPassMs: Double = 15_000) {
        self.intervalMs = intervalMs
        self.secondPassMs = secondPassMs
    }

    /// The pass a refresh may run as now, or nil: 1 is the first for this
    /// item, 2 the second after `secondPassMs`, 3 every later one at
    /// `intervalMs` spacing. Records the moment when it admits.
    mutating func admittedPass(itemId: String, nowMs: Double) -> Int? {
        if let first = secondPassDue[itemId] {
            guard nowMs - first >= secondPassMs else { return nil }
            secondPassDue[itemId] = nil
            lastRefreshMs[itemId] = nowMs
            return 2
        }
        if let last = lastRefreshMs[itemId] {
            guard nowMs - last >= intervalMs else { return nil }
            lastRefreshMs[itemId] = nowMs
            return 3
        }
        lastRefreshMs[itemId] = nowMs
        secondPassDue[itemId] = nowMs
        return 1
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
        case .book: return ItemNamespace.isLocal(itemId) ? nil : .books
        case .podcast: return ItemNamespace.isABSPodcast(itemId) ? .serverPodcasts : nil
        default: return nil
        }
    }
}
