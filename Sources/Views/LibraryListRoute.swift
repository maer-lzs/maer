// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation

/// "every row is the preview of a page". A capped row's heading pushes
/// one of these; the destination is the EXISTING `BrowseBooksScreen` (title +
/// cover grid), so no new surface is introduced. Only a way to reach the full
/// list behind a preview.
///
/// The route carries no data: the page reads the current list from the view
/// model, so a book that finishes while the page is open leaves it, exactly as
/// it leaves the row underneath.
nonisolated enum LibraryListRoute: Hashable {
    case continueListening
    case recentlyAdded
    /// The full stock behind the "All Books" PREVIEW. This
    /// reverses the earlier "deliberately no allBooks" note. Back then the
    /// section WAS the full list, so a chevron pointed at itself (G8). DIE
    /// REGEL came later: tab roots are previews, the full stock lives one
    /// level down, and the chevron is earned by counting again.
    case allBooks

    /// Same wording as the row it belongs to. The page IS that row, unabridged.
    var title: String {
        switch self {
        case .continueListening: String(localized: "Keep Listening")
        case .recentlyAdded:     String(localized: "Recently Added")
        case .allBooks:          String(localized: "All Books")
        }
    }
}
