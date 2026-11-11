// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation
import os

/// What a start remembers before it waits (for the server, for a title to
/// resolve, for the stored library), and asks again after: the title, the
/// player and how many holds (a pause, a stop, the begin of an
/// interruption) there were. Only when all three still stand does the
/// start act; otherwise something the person did meanwhile wins, and a
/// line says so. One rule for the start, the standby mirror, a foreign
/// claim and the door to continue listening.
nonisolated struct WaitWindow: Equatable, Sendable {
    let itemId: String?
    let player: ObjectIdentifier?
    let holds: Int

    /// Whether what was remembered before the wait still stands after it.
    static func stillStands(_ before: WaitWindow, _ after: WaitWindow) -> Bool {
        before == after
    }
}

/// A wait with a hard limit: returns when `task` ended or `limit` passed,
/// whichever comes first, and never later. The task runs on either way. A
/// task group would wait for its child at the end of its scope even after
/// cancelling it, and a child that waits on another task's value is not
/// cancelled by that.
nonisolated enum WaitLimit {
    static func wait(for task: Task<Void, Never>, atMost limit: Duration) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let once = OSAllocatedUnfairLock(initialState: false)
            let resume: @Sendable () -> Void = {
                let first = once.withLock { done in
                    defer { done = true }
                    return !done
                }
                if first { continuation.resume() }
            }
            Task {
                await task.value
                resume()
            }
            Task {
                try? await Task.sleep(for: limit)
                resume()
            }
        }
    }
}
