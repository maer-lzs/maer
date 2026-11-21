// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation

nonisolated enum MiniBarFill: Equatable, Sendable {
    case session
    case waiting(String)
    case lastPlayed(String)
    case empty

    static func of(hasSession: Bool, waiting: [String], lastPlayed: String?) -> MiniBarFill { .session }
}
