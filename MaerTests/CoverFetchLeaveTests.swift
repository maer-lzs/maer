// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// The network path of every tile goes through one shared fetch per
/// address. A tile that left the screen leaves that fetch; the fetch is
/// cancelled only when no tile waits any more, so a visible tile never
/// gets the answer of one that left.
@MainActor
struct CoverFetchLeaveTests {
    private func url() -> URL { URL(string: "https://covers.example.invalid/leave-\(UUID().uuidString).jpg")! }

    /// A fetch that answers `absent` after `wait`, or `unanswered` when it
    /// is cancelled before.
    private func slow(_ wait: Duration) -> () async -> Artwork.Fetched {
        {
            do {
                try await Task.sleep(for: wait)
                return .absent
            } catch {
                return .unanswered
            }
        }
    }

    private func name(_ fetched: Artwork.Fetched) -> String {
        switch fetched {
        case .picture: return "picture"
        case .absent: return "absent"
        case .unanswered: return "unanswered"
        }
    }

    @Test("a tile that waits alone and leaves cancels the fetch")
    func theOnlyTileThatLeavesCancelsTheFetch() async throws {
        let address = url()
        let started = ContinuousClock.now
        let tile = Task { @MainActor in await CoverFetchCoalescer.fetch(address, work: slow(.seconds(3))) }
        try await Task.sleep(for: .milliseconds(50))
        tile.cancel()
        let answer = await tile.value
        #expect(name(answer) == "unanswered", "the fetch ran on for a tile that left: \(name(answer))")
        #expect(ContinuousClock.now - started < .seconds(2), "the tile that left waited for the whole fetch")
    }

    @Test("two tiles share the fetch, one leaves: the other gets the answer")
    func aSharedFetchGoesOnWhileATileWaits() async throws {
        let address = url()
        let left = Task { @MainActor in await CoverFetchCoalescer.fetch(address, work: slow(.milliseconds(300))) }
        try await Task.sleep(for: .milliseconds(20))
        let visible = Task { @MainActor in await CoverFetchCoalescer.fetch(address, work: slow(.milliseconds(300))) }
        try await Task.sleep(for: .milliseconds(20))
        left.cancel()
        #expect(name(await visible.value) == "absent", "the visible tile got the answer of the one that left")
        _ = await left.value
    }
}
#endif
