// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation

/// The one rule behind "for all shows": a show follows the general value
/// unless it stores its own, and a stored value that equals the general one
/// counts as following. Values are the stored raw strings, so every field
/// for all shows shares it.
nonisolated enum PodcastGeneralRule {
    /// What a change of the general value does to the shows' own values.
    enum Answer: Equatable, Sendable {
        /// Every show follows the new value; their own values go.
        case overwriteAll
        /// Shows with their own value keep it; only followers move.
        case keepOwn
    }

    /// The value a show acts on.
    static func effective(stored: String?, general: String) -> String {
        stored ?? general
    }

    /// The shows whose own value differs from the general one, sorted, so
    /// a list and a count read the same answer.
    static func own(stored: [String: String], general: String) -> [String] {
        stored.filter { $0.value != general }.map(\.key).sorted()
    }

    /// The stored values a change removes. With `keepOwn` only those equal
    /// to the old general value, which were following it anyway and would
    /// otherwise stay behind as silent copies of the old value.
    static func cleared(stored: [String: String], old: String, answer: Answer) -> [String] {
        switch answer {
        case .overwriteAll: return stored.keys.sorted()
        case .keepOwn: return stored.filter { $0.value == old }.map(\.key).sorted()
        }
    }
}
