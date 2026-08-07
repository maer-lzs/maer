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
    /// Auftrag J1: the full stock behind the "All Books" PREVIEW. This
    /// reverses the earlier "deliberately no allBooks" note — back then the
    /// section WAS the full list, so a chevron pointed at itself (G8). DIE
    /// REGEL came later: tab roots are previews, the full stock lives one
    /// level down, and the chevron is earned by counting again.
    case allBooks

    /// Same wording as the row it belongs to — the page IS that row, unabridged.
    var title: String {
        switch self {
        case .continueListening: String(localized: "Continue")
        case .recentlyAdded:     String(localized: "Recently Added")
        case .allBooks:          String(localized: "All Books")
        }
    }
}
