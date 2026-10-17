// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation

/// The search stands on the root of a tab's stack, and a push from it
/// closes it, except when it opens a page of the books tab (an author, a
/// series, the authors, series or genres): then it steps aside for that
/// page and comes back, with its query and its results, when the stack is
/// back at the depth it stepped aside at. A book opened from the page and
/// left again leads back to the page first, then to the search.
nonisolated struct SearchReturn: Equatable, Sendable {
    enum Step: Equatable, Sendable {
        case none
        /// A push left the search: it closes, its query goes.
        case close
        /// A page of the books tab opened from the search: the search
        /// hides and keeps its query and results.
        case stepAside
        /// The stack is back where the search stepped aside: it stands
        /// again.
        case comeBack
    }

    /// The depth of the stack the search stepped aside at; nil when it did
    /// not.
    private(set) var asideAt: Int?
    /// Set right before the search pushes a page of the books tab, taken by
    /// the push that follows.
    private(set) var pageOpening = false

    mutating func opensPage() { pageOpening = true }

    /// What the search does when the depth of its stack changes from `old`
    /// to `new`; `showing` says whether it stands right now.
    mutating func pathChanged(from old: Int, to new: Int, showing: Bool) -> Step {
        if showing, new > old {
            defer { pageOpening = false }
            guard pageOpening else { return .close }
            asideAt = old
            return .stepAside
        }
        if let at = asideAt, new <= at {
            asideAt = nil
            return .comeBack
        }
        return .none
    }

    /// The search opened anew, closed, or the tab changed: nothing to come
    /// back to.
    mutating func forget() {
        asideAt = nil
        pageOpening = false
    }
}
