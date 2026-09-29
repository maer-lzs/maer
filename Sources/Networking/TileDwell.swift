// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation

/// The short stay a tile has on screen before its automatic question goes
/// to the network: a cover, a runtime, a metadata record, a feed image, an
/// artist portrait, a station logo. Memory and disk answer at once; only a
/// question the caches could not answer stays first.
///
/// Measured before the rule (a scroll run of 24.09.): every tile asked the
/// moment it appeared, 229 cover fetches and 119 metadata fetches at
/// archive.org in one minute of scrolling, most of them for tiles that
/// were gone before the answer came. The stay is counted from the moment
/// the tile appeared, in the tile's own task: a tile that scrolls away
/// cancels its task, and with it the stay, and nothing is asked. A second
/// question of the same tile waits only the rest of its stay.
///
/// Chosen, not measured: 0.4 s for a cover, 0.8 s for a lookup. A cover
/// that appears 0.4 s later is hardly seen when the scroll stops; while it
/// flies past, most questions are never asked.
nonisolated enum TileDwell {
    /// Before a cover is fetched from the network.
    static let cover: Duration = .milliseconds(400)
    /// Before a runtime, a metadata record, a portrait or a logo is asked for.
    static let lookup: Duration = .milliseconds(800)

    /// The moment a tile appeared, carried in its task.
    struct Stay: Sendable {
        let began: ContinuousClock.Instant
    }

    @TaskLocal static var stay: Stay?

    /// Runs `body` as the questions of a tile that just appeared, on the
    /// caller's isolation. Every network question inside stays first.
    nonisolated(nonsending)
    static func standing<T>(_ body: nonisolated(nonsending) () async throws -> T) async rethrows -> T {
        try await $stay.withValue(Stay(began: ContinuousClock.now), operation: body)
    }

    /// Whether the tile has stood `duration` since it appeared, waiting for
    /// the rest of it when it has not. True at once for a question outside
    /// a tile and for a tile that stood that long already; false when the
    /// tile left during the wait, and then nothing is asked.
    static func stood(_ duration: Duration) async -> Bool {
        guard let stay else { return true }
        let until = stay.began + duration
        guard until > ContinuousClock.now else { return true }
        do {
            try await Task.sleep(until: until, clock: .continuous)
            return true
        } catch {
            // The tile left during its stay: the only thing the sleep can
            // throw is the cancellation of the tile's task.
            return false
        }
    }
}
