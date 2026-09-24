// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation

/// The rule for a new sync password, held by the client because the service
/// never sees a password and cannot judge one (contract version 6).
///
/// Swift strings count characters as a person sees them and compare by
/// canonical equivalence, so a letter typed as one code point or as two
/// counts once and is the same letter. The rule relies on that and never
/// compares bytes.
nonisolated enum PasswordRule {
    static let minimumCharacters = 12

    enum Verdict: Equatable {
        case acceptable
        case tooShort(missing: Int)
        /// The move to version 6 and every change must set a password the
        /// service has not seen; the old one reached it.
        case sameAsCurrent
        /// The new password and its repetition differ. With one secret a
        /// typo costs the account and the feed credentials, so it is typed
        /// twice.
        case repeatDiffers
    }

    /// The page's question: the repetition first, then the rule.
    static func check(new: String, repeated: String, current: String?) -> Verdict {
        new == repeated ? check(new: new, current: current) : .repeatDiffers
    }

    static func check(new: String, current: String?) -> Verdict {
        if let current, new == current { return .sameAsCurrent }
        return new.count >= minimumCharacters ? .acceptable : .tooShort(missing: minimumCharacters - new.count)
    }
}
