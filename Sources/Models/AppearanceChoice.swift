// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation

/// What the person chose under Appearance: follow the system, or one of
/// the two schemes. The stored value is a string; this is the one place
/// that reads it, so every surface asks the same question.
nonisolated enum AppearanceChoice: String, CaseIterable, Sendable {
    case system
    case light
    case dark

    /// An unknown or missing value follows the system: a setting nobody
    /// set is not a decision.
    static func of(_ raw: String?) -> AppearanceChoice {
        guard let raw, let choice = AppearanceChoice(rawValue: raw) else { return .system }
        return choice
    }
}
