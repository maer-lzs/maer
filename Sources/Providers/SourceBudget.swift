// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation
import OSLog

/// 🟡 P7: the answer to "source instead of start". A composed surface waits
/// for its sources — but it must never wait WITHOUT END on one of them. A
/// homeserver that is down (or a reverse proxy still coming up) answers
/// slowly rather than at all, and the old serial chain in `HomeView.compute`
/// held every section behind the slowest one: the whole start page stayed
/// empty while a single server was missing.
///
/// The budget does NOT cancel the work — the loads are idempotent and keep
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
    /// budget runs out — the source is not cancelled, it simply stops being
    /// waited for.
    static func value<T: Sendable>(default fallback: T, label: StaticString = #function,
                                   _ work: @escaping @Sendable () async -> T) async -> T {
        await withTaskGroup(of: T?.self) { group in
            group.addTask { await work() }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                return nil
            }
            defer { group.cancelAll() }
            for await first in group {
                if let first { return first }
                Logger.library.notice("SOURCE budget exceeded (\(String(describing: label), privacy: .public)) — rendering without it, the load keeps running")
                return fallback
            }
            return fallback
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
