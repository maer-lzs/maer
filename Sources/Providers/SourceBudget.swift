// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation
import OSLog

/// 🟡 The answer to "source instead of start". A composed surface waits
/// for its sources. But it must never wait WITHOUT END on one of them. A
/// homeserver that is down (or a reverse proxy still coming up) answers
/// slowly rather than at all, and the old serial chain in `HomeView.compute`
/// held every section behind the slowest one: the whole start page stayed
/// empty while a single server was missing.
///
/// The budget does NOT cancel the work. The loads are idempotent and keep
/// running, so their result lands in the NEXT pass through the calm gate.
/// It only bounds how long the composing surface waits before rendering what
/// it already has. That is the serverless principle applied to Start: what
/// is there appears, what is missing is missing (visibly, per section).
///
/// Deliberately NOT a timeout on the network layer: a download or a playback
/// request may take as long as it takes. This is about a surface's patience,
/// not about a request's lifetime.
nonisolated enum SourceBudget {
    /// How long a composed surface waits for ONE source. Measured against the
    /// device case: a reachable server answers these calls in well under a
    /// second; the unreachable Tiny made them run into the URLSession
    /// timeout (60 s+), which is what emptied the page.
    static let seconds: Double = 4

    /// Await `work`, but at most for the budget. Returns `fallback` when the
    /// budget runs out. The source is not cancelled, it simply stops being
    /// waited for.
    ///
    /// **Store-backed sources:** for them the
    /// promise "the load lands in the next pass" holds, because the store
    /// publishes. For DIRECT values it did not. A result arriving after the
    /// deadline was dropped, and nothing triggered a recompute, so the row
    /// stayed empty until a tab switch. `onLate` closes that: a late result
    /// applies ITSELF. The contract now reads: **no result expires, no user
    /// action needed.**
    ///
    /// `budget` is the app's `seconds` for every caller in the app; only the
    /// witnesses shorten it, because what they tell apart is the value that
    /// arrives, not how long the wait was.
    static func value<T: Sendable>(default fallback: T, label: StaticString = #function,
                                   budget: Double = seconds,
                                   onLate: (@Sendable (T) async -> Void)? = nil,
                                   _ work: @escaping @Sendable () async -> T) async -> T {
        // Deliberately NOT a TaskGroup: a group awaits ALL its children when
        // the block ends, so the surviving work task would hold the caller
        // for its full runtime. The budget would stop bounding anything
        // (measured: 60 s instead of 4). The work therefore runs as its own
        // task, and a one-shot gate hands the FIRST of the two outcomes to
        // the caller.
        let gate = FirstAnswer<T>()
        let workTask = Task { await work() }
        Task {
            let value = await workTask.value
            if await gate.claim(value) == false {
                // The deadline won. This value is LATE and applies itself
                // (no result expires, no user action needed).
                await onLate?(value)
            }
        }
        Task {
            try? await Task.sleep(nanoseconds: UInt64(budget * 1_000_000_000))
            if await gate.claim(fallback) {
                Logger.library.notice("SOURCE budget exceeded (\(String(describing: label), privacy: .public)) — rendering without it; the late result applies itself")
            }
        }
        return await gate.value()
    }

    /// One-shot handover: whoever claims first answers the caller, the other
    /// learns that it was late. The continuation is resumed exactly once.
    private actor FirstAnswer<T: Sendable> {
        private var answer: T?
        private var waiter: CheckedContinuation<T, Never>?

        /// - Returns: true if THIS call was the first one.
        func claim(_ value: T) -> Bool {
            guard answer == nil else { return false }
            answer = value
            if let waiter { self.waiter = nil; waiter.resume(returning: value) }
            return true
        }

        func value() async -> T {
            if let answer { return answer }
            return await withCheckedContinuation { continuation in
                if let answer { continuation.resume(returning: answer) }
                else { waiter = continuation }
            }
        }
    }

    /// The same for work without a result.
    static func run(label: StaticString = #function,
                    _ work: @escaping @Sendable () async -> Void) async {
        _ = await value(default: false, label: label) {
            await work()
            return true
        }
    }
}
