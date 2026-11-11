// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation

/// When the pages of a library are the whole library. Only a whole list is
/// kept as the offline copy and hands out its ids to the cleanup, which
/// removes the rows of every book it does not name.
nonisolated enum LibraryCompleteness {
    /// The total of a library whose server answered none.
    static let unknownTotal = Int.max

    /// Whether the load asks for another page: the distinct ids have not
    /// reached the server's total, or the total is unknown.
    static func asksMore(distinctIds: Int, total: Int) -> Bool {
        total == unknownTotal || distinctIds < total
    }

    /// Whether the loaded pages are the whole library: as many distinct ids
    /// as the server's total (a book sent twice on two pages is one), or,
    /// without a total, a page that came back shorter than asked ended it.
    static func isWhole(distinctIds: Int, total: Int, endedShort: Bool) -> Bool {
        total == unknownTotal ? endedShort : distinctIds >= total
    }
}
