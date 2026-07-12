import SwiftUI
import Combine

/// Shared state of the collapsible bottom zone. Every scrolled surface of the
/// app (library, podcast home, detail pages) reports its scroll offset via
/// `reportsBottomBarScroll()`; `LibraryView` reads `collapsed` and builds the
/// bar accordingly — so the mini-player behaves the same everywhere.
@MainActor
final class BottomBarState: ObservableObject {
    static let shared = BottomBarState()
    private init() {}

    @Published var scrollY: CGFloat = 0
    /// A home tap expands again; the next scroll re-enables collapsing.
    @Published var forceExpanded = false

    var collapsed: Bool { scrollY > 60 && !forceExpanded }

    func report(_ y: CGFloat) {
        scrollY = y
        if forceExpanded { forceExpanded = false }
    }

    func expand() { forceExpanded = true }

    /// On a tab switch: expand (avoid the stale offset of the other surface).
    func reset() { scrollY = 0; forceExpanded = false }
}

extension View {
    /// Attach to EVERY scrolled surface — reports the offset to the bottom zone.
    func reportsBottomBarScroll() -> some View {
        onScrollGeometryChange(for: CGFloat.self) { $0.contentOffset.y } action: { _, y in
            BottomBarState.shared.report(y)
        }
    }
}
