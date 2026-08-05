import Foundation

/// 3a3b1aa: "every row is the preview of a page". A capped row's heading pushes
/// one of these; the destination is the EXISTING `BrowseBooksScreen` (title +
/// cover grid), so no new surface is introduced — only a way to reach the full
/// list behind a preview.
///
/// The route carries no data: the page reads the current list from the view
/// model, so a book that finishes while the page is open leaves it, exactly as
/// it leaves the row underneath.
nonisolated enum LibraryListRoute: Hashable {
    case continueListening
    case recentlyAdded
    // Deliberately NO `allBooks`: that section already IS the full list
    // (staged paging over the whole stock), so a chevron would point at the
    // surface you are standing on — the affordance-without-target G8 forbids.

    /// Same wording as the row it belongs to — the page IS that row, unabridged.
    var title: String {
        switch self {
        case .continueListening: String(localized: "Continue")
        case .recentlyAdded:     String(localized: "Recently Added")
        }
    }
}
