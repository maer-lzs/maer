// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation

/// Sign-in to Jellyfin without a password: Mär shows a code, the person
/// approves it in a Jellyfin session where they are signed in, and Mär
/// trades the code's secret for a token (`JellyfinClient`).
nonisolated enum JellyfinQuickConnect {
    /// What one look at the code says.
    enum Answer: Equatable, Sendable {
        case waiting
        case approved
        /// The server does not know the secret: expired or never issued.
        case gone
        case failed(status: Int?)
    }

    /// How a flow ends.
    enum Outcome: Equatable, Sendable {
        case signedIn
        case gone
        case cancelled
        case failed(String)

        /// The sentence the page shows; a cancel says nothing.
        var sentence: String? { nil }
    }

    static func answer(status: Int?, authenticated: Bool?) -> Answer { .waiting }

    static func offered(status: Int?, body: Data) -> Bool { false }

    static var goneSentence: String {
        String(localized: "The code is no longer valid. Start Quick Connect again.")
    }

    @MainActor
    static func run(look: @MainActor () async -> Answer,
                    finish: @MainActor () async -> String?,
                    wait: @MainActor () async throws -> Void) async -> Outcome {
        .cancelled
    }
}
