// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation

/// At most `limit` reads at one host at once, across every row and page
/// that asks it; the next waits for a free one, in the order they came.
/// archive.org serves the classical row, the netlabels, LibriVox popularity,
/// the audiobooks and Old Time Radio from one host, and a start fetches
/// them together.
actor HostReads {
    static let archive = HostReads(limit: 4)

    let limit: Int
    private var running = 0
    private var waiting: [CheckedContinuation<Void, Never>] = []

    init(limit: Int) { self.limit = limit }

    func run<T: Sendable>(_ op: @Sendable () async throws -> T) async rethrows -> T {
        await take()
        defer { give() }
        return try await op()
    }

    private func take() async {
        if running < limit { running += 1; return }
        await withCheckedContinuation { waiting.append($0) }
    }

    /// A free read goes straight to the next in line, so the count stays.
    private func give() {
        if waiting.isEmpty { running -= 1 } else { waiting.removeFirst().resume() }
    }
}
