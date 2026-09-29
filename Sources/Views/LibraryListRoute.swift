// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import SwiftUI

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
    /// The full stock behind the "All Books" PREVIEW. Tab roots are
    /// previews, the full stock lives one level down, and the chevron is
    /// earned by counting again, so it never points at the list it sits on.
    case allBooks
    /// Every book of one author, and of one series. The books tab reaches
    /// them through its browse deck; search reaches the SAME page through
    /// this route instead of a drill level of its own, which was only
    /// rendered without a query and so did nothing on a hit.
    case author(String)
    case series(String)

    /// Same wording as the row it belongs to. The page IS that row, unabridged.
    var title: String {
        switch self {
        case .continueListening: String(localized: "Keep Listening")
        case .recentlyAdded:     String(localized: "Recently Added")
        case .allBooks:          String(localized: "All Books")
        case .author(let name):  name
        case .series(let name):  name
        }
    }
}

/// Push a library list from a surface that is not a link (the search
/// results). Same pattern as the podcast and catalogue routes.
nonisolated struct PushLibraryListRouteKey: EnvironmentKey {
    static let defaultValue: @MainActor (LibraryListRoute) -> Void = { _ in }
}

extension EnvironmentValues {
    var pushLibraryListRoute: @MainActor (LibraryListRoute) -> Void {
        get { self[PushLibraryListRouteKey.self] }
        set { self[PushLibraryListRouteKey.self] = newValue }
    }
}
