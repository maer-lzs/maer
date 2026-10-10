// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import SwiftUI

/// "every row is the preview of a page". A capped row's heading pushes
/// one of these; the destination of a book list is the EXISTING
/// `BrowseBooksScreen` (title + cover grid). The groups of a kind have their
/// one page (`BookGroupsScreen`), and local files their management page.
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
    /// Every book of one author, of one series, of one genre. The books tab
    /// and the search deck reach them through the page of their groups; a
    /// typed hit reaches the SAME page through this route.
    case author(String)
    case series(String)
    case genre(String)
    /// The groups of one kind, each with its count (`BookGroupsScreen`).
    /// The books tab and the search deck open this one page; the search
    /// keeps no drill level of its own.
    case groups(BookGroupKind)
    /// The files on this device, managed (`LocalFilesView`).
    case localFiles

    /// The entries of the books tab's tile deck, in order. Genres stand
    /// in the search deck only.
    static let bookTabEntries: [LibraryListRoute] = [.groups(.series), .groups(.authors), .localFiles]

    /// The books of one group of a kind: the route a row of the groups page
    /// opens, the same a typed hit opens.
    static func books(of kind: BookGroupKind, named name: String) -> LibraryListRoute {
        switch kind {
        case .authors: .author(name)
        case .series: .series(name)
        case .genres: .genre(name)
        }
    }

    /// Same wording as the row it belongs to. The page IS that row, unabridged.
    var title: String {
        switch self {
        case .continueListening: String(localized: "Keep Listening")
        case .recentlyAdded:     String(localized: "Recently Added")
        case .allBooks:          String(localized: "All Books")
        case .author(let name):  name
        case .series(let name):  name
        case .genre(let name):   name
        case .groups(let kind):  kind.title
        case .localFiles:        String(localized: "Local Files")
        }
    }

    /// The glyph of a tile that opens this route; nil for the routes that
    /// no tile opens.
    var systemImage: String? {
        switch self {
        case .groups(let kind): kind.systemImage
        case .localFiles: "folder"
        case .continueListening, .recentlyAdded, .allBooks, .author, .series, .genre: nil
        }
    }

    /// The accessibility handle of the tile that opens this route.
    var tileId: String {
        switch self {
        case .groups(let kind): "books-tab-\(kind.rawValue)"
        case .localFiles: "books-tab-local-files"
        case .continueListening, .recentlyAdded, .allBooks, .author, .series, .genre: "books-tab-route"
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
