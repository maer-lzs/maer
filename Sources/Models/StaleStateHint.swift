// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation

/// The line above a tab that shows the cached library instead of the
/// server's answer. It names why: no network at all, or a network without
/// the server. The one input is the app's network value (`\.isOnline`).
nonisolated enum StaleStateHint: Equatable, Sendable {
    case offline
    case serverUnreachable

    static func of(isOnline: Bool) -> StaleStateHint {
        isOnline ? .serverUnreachable : .offline
    }

    var text: LocalizedStringResource {
        switch self {
        case .offline: return "Offline: last known state"
        case .serverUnreachable: return "Server unreachable: last known state"
        }
    }

    var symbol: String {
        switch self {
        case .offline: return "wifi.slash"
        case .serverUnreachable: return "server.rack"
        }
    }
}
