// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation

/// What the mini player shows, which always stands: the running session;
/// without one the first order waiting in Up Next, else the title heard
/// last, else that nothing waits. Without a session a tap opens Up Next.
nonisolated enum MiniBarFill: Equatable, Sendable {
    case session
    case waiting(String)
    case lastPlayed(String)
    case empty

    static func of(hasSession: Bool, waiting: [String], lastPlayed: String?, heardLast: String? = nil) -> MiniBarFill {
        if hasSession { return .session }
        if let first = waiting.first { return .waiting(first) }
        if let lastPlayed, !lastPlayed.isEmpty { return .lastPlayed(lastPlayed) }
        // A title heard to its end leaves the standby, and is still the
        // one heard last.
        if let heardLast, !heardLast.isEmpty { return .lastPlayed(heardLast) }
        return .empty
    }
}
