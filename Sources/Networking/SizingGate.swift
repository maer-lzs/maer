// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation

/// At most `width` covers are brought to display or cell size at once; the
/// others wait in the order they asked. Bringing a large cover to size
/// decodes it whole, so eight cells at once held eight decodes (measured:
/// 610 MB peak for eight 3000 px covers, 194 MB one after the other). A
/// waiter whose task is cancelled, a cell that left the screen, gives its
/// place up without decoding.
actor SizingGate {
    private let width: Int
    private var running = 0
    private struct Waiter {
        let id: UUID
        let turn: CheckedContinuation<Void, Error>
    }
    private var waiting: [Waiter] = []
    /// The most that ran at once since the start, for the witness.
    private(set) var mostAtOnce = 0
    /// How many hold a place or wait for one, for the witness: it lets the
    /// next ask only after the last one stands in the gate.
    var asked: Int { running + waiting.count }

    init(width: Int) {
        self.width = width
    }

    /// Waits for a place; throws `CancellationError` when the task is
    /// cancelled before its turn. Every `enter` that returns is followed
    /// by one `leave`.
    func enter() async throws {
        if running < width, waiting.isEmpty {
            take()
            return
        }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (turn: CheckedContinuation<Void, Error>) in
                if Task.isCancelled {
                    turn.resume(throwing: CancellationError())
                    return
                }
                waiting.append(Waiter(id: id, turn: turn))
            }
        } onCancel: {
            Task { await self.giveUp(id) }
        }
    }

    func leave() {
        running -= 1
        guard !waiting.isEmpty else { return }
        let next = waiting.removeFirst()
        take()
        next.turn.resume()
    }

    private func take() {
        running += 1
        mostAtOnce = max(mostAtOnce, running)
    }

    /// A cancelled waiter leaves the line. One that already got its place
    /// runs and leaves as usual.
    private func giveUp(_ id: UUID) {
        guard let at = waiting.firstIndex(where: { $0.id == id }) else { return }
        waiting.remove(at: at).turn.resume(throwing: CancellationError())
    }
}
