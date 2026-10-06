// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation

/// What a load takes as the progress of its books: the fetched answer, or,
/// when the fetch failed, what was known before. A failed fetch replaces
/// no known progress; an empty map from a failure wiped every bar of the
/// library while its pages had arrived. One answer for every load path.
nonisolated enum ProgressAnswer {
    static func of(_ fetched: [String: BookProgress]?,
                   known: [String: BookProgress]) -> [String: BookProgress] {
        fetched ?? known
    }
}
