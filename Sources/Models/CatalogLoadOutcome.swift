// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation

/// What one catalogue fetch of a loader hands back to its page. A failure is
/// an answer the page shows; a cancellation is not a failure and leaves the
/// page as it was. One shape for every catalogue loader, so the pages read
/// them alike.
nonisolated enum CatalogLoadOutcome: Equatable {
    /// `fetched` is what the service sent, before mapping; the end of a paged
    /// list is read from it, never from the mapped count.
    case loaded(items: [LibraryItem], fetched: Int)
    case failed(reason: String)
    case cancelled

    /// The reason a failed fetch hands back: the catalogue's own wording
    /// where it has one, else the one rule for a failure's log reason. Pages
    /// never show it as a sentence; it names the failure in the log.
    static func reason(_ error: Error) -> String {
        FreeCatalog.failureReason(error) ?? FailureReason.of(error)
    }
}
