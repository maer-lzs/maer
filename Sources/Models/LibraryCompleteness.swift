// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation

/// When the pages of a library are the whole library, and when the load
/// asks another page. Only a whole list is kept as the offline copy and
/// hands out its ids to the cleanup, which removes the rows of every book
/// it does not name.
nonisolated enum LibraryCompleteness {
    /// The total of a library whose server answered none.
    static let unknownTotal = Int.max

    /// What a load does after a page.
    enum Step: Equatable, Sendable {
        /// Asks the next page.
        case askMore
        /// As many distinct ids as the server's total: whole.
        case reachedTotal
        /// Without a total, a page shorter than asked ended the list: whole.
        case endedShort
        /// The page brought no id not held already (an empty page with a
        /// total not reached, or a source that ignores the page and sends
        /// the same again): the load stops, and the list is not whole.
        case stalled
    }

    /// The step after a page. With a total, only the distinct ids decide:
    /// a short page in the middle does not end the list. Without one, a
    /// short page ends it. A page that brings nothing new stops the load
    /// either way, so a source that ignores the page never loops, and an
    /// empty first page without a total is no empty library.
    static func afterPage(distinctBefore: Int, distinctAfter: Int, pageCount: Int, pageSize: Int, total: Int) -> Step {
        if total != unknownTotal, distinctAfter >= total { return .reachedTotal }
        if distinctAfter <= distinctBefore {
            // Without a total, an empty page after books is the end of a list
            // as long as a whole number of pages; an empty first page or a
            // page that sent only books held already is no end.
            return total == unknownTotal && pageCount == 0 && distinctBefore > 0 ? .endedShort : .stalled
        }
        if total == unknownTotal, pageCount < pageSize { return .endedShort }
        return .askMore
    }

    /// Whether the load that stopped at this step holds the whole library.
    static func isWhole(_ step: Step) -> Bool {
        step == .reachedTotal || step == .endedShort
    }
}
