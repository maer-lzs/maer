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
        var sentence: String? {
            switch self {
            case .signedIn, .cancelled: return nil
            case .gone: return JellyfinQuickConnect.goneSentence
            case .failed(let sentence): return sentence
            }
        }
    }

    /// What `/QuickConnect/Connect` says: 200 with `Authenticated`, a 404
    /// for a secret the server does not know (expired or never issued);
    /// any other status is the client's failure for it.
    static func answer(status: Int?, authenticated: Bool?) -> Answer {
        switch (status, authenticated) {
        case (200?, true?): return .approved
        case (200?, false?): return .waiting
        case (404?, _): return .gone
        default: return .failed(status: status)
        }
    }

    /// `/QuickConnect/Enabled` answers a bare `true` when the server offers it.
    static func offered(status: Int?, body: Data) -> Bool {
        status == 200 && String(decoding: body, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) == "true"
    }

    /// How long the page waits between two looks at the code.
    static let lookInterval: Duration = .seconds(3)

    /// The wait between two looks; a cancel throws.
    static func waitBetweenLooks() async throws { try await Task.sleep(for: lookInterval) }

    /// The rest after typing before the server at a typed address is asked
    /// whether it offers Quick Connect; a new keystroke cancels it.
    static func restBeforeAsking() async throws { try await Task.sleep(for: .milliseconds(600)) }

    static var goneSentence: String {
        String(localized: "The code is no longer valid. Start Quick Connect again.")
    }

    /// The flow behind a shown code: look, wait while it waits, finish once
    /// it is approved (`finish` answers nil when the account is kept). A
    /// cancel, during a wait or before a look, ends it without a sentence.
    @MainActor
    static func run(look: @MainActor () async -> Answer,
                    finish: @MainActor () async -> String?,
                    wait: @MainActor () async throws -> Void) async -> Outcome {
        while !Task.isCancelled {
            switch await look() {
            case .waiting:
                do { try await wait() } catch { return .cancelled }
            case .approved:
                if let failure = await finish() { return .failed(failure) }
                return .signedIn
            case .gone:
                return .gone
            case .failed(let status):
                // Through the one place, so the status stands behind the sentence.
                return .failed(ErrorSentence.of(JellyfinClient.failure(forStatus: status)))
            }
        }
        return .cancelled
    }
}
