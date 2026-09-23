// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation

/// The sentence when one of two music servers does not answer. Without it
/// the page would show half the library as if it were the whole of it.
nonisolated enum MusicSourceFailure {
    /// Nil when every source answered, and nil when none did: then the
    /// page has its own error state and nothing is half shown. `names` are
    /// the sources' own names (`MusicSourceName`), the capsule's words.
    static func sentence(failed: [String], all: [String], names: [String: String] = [:]) -> String? {
        let answered = all.filter { !failed.contains($0) }
        guard !failed.isEmpty, !answered.isEmpty else { return nil }
        let name = { (id: String) in names[id] ?? MusicSourceName.name(providerId: id, reportedType: nil) }
        let down = failed.map(name).joined(separator: ", ")
        let up = answered.map(name).joined(separator: ", ")
        return String(localized: "\(down) is not answering right now; showing only what \(up) has.")
    }
}
