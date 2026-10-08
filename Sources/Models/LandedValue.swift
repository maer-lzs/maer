// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation

/// When an answer of a start-page pass replaces what landed before.
///
/// A pass asks its sources under a budget; an answer can come in time, come
/// late, or not come at all (a failure, or the budget ran out). No answer
/// is no knowledge, so it never replaces a value that landed. And a late
/// answer of an older pass never replaces what a newer pass answered.
nonisolated enum LandedValue {
    /// Whether the answer of `pass` replaces the value a pass numbered
    /// `landedPass` put there (0: nothing landed yet).
    static func replaces(answered: Bool, pass: Int, landedPass: Int) -> Bool {
        answered && pass >= landedPass
    }
}
