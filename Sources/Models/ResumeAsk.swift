// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation

/// What a request from outside (Siri, a quick action, the widget's link)
/// can be told before the app opens, and how long it stands.
nonisolated enum ResumeAsk {
    /// How long a request waits for the library before it goes.
    static let standsAtMost: TimeInterval = 120

    /// Whether a request made at `askedAt` still stands; one without a
    /// moment stands (it was made before the moment was noted).
    static func stillStands(askedAt: Date?, now: Date) -> Bool {
        guard let askedAt else { return true }
        return now.timeIntervalSince(askedAt) <= standsAtMost
    }

    /// A continue request finds nothing on a device without a last played
    /// title and without an open player: it says so instead of succeeding.
    static func continueFindsNothing(lastPlayedId: String?, hasActivePlayer: Bool) -> Bool {
        !hasActivePlayer && (lastPlayedId ?? "").isEmpty
    }

    /// The sentence Siri says for a request that finds nothing.
    struct Refusal: Error, CustomLocalizedStringResourceConvertible {
        let localizedStringResource: LocalizedStringResource
        init(_ sentence: LocalizedStringResource) { localizedStringResource = sentence }
    }
}
