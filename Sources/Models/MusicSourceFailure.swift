// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation

/// The sentence when one of two music servers does not answer. Without it
/// the page would show half the library as if it were the whole of it.
nonisolated enum MusicSourceFailure {
    /// The name a person knows a music source by, from its provider id.
    static func name(providerId: String) -> String {
        switch providerId {
        case "jf": "Jellyfin"
        case "sub": "Subsonic"
        default: providerId
        }
    }

    /// Nil when every source answered, and nil when none did: then the
    /// page has its own error state and nothing is half shown.
    static func sentence(failed: [String], all: [String]) -> String? {
        let answered = all.filter { !failed.contains($0) }
        guard !failed.isEmpty, !answered.isEmpty else { return nil }
        let down = failed.map(name(providerId:)).joined(separator: ", ")
        let up = answered.map(name(providerId:)).joined(separator: ", ")
        return String(localized: "\(down) is not answering right now; showing only what \(up) has.")
    }
}
