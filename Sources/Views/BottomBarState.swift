import SwiftUI
import Combine

/// Shared state of the collapsible bottom zone. Every scrolled surface of the
/// app (library, podcast home, detail pages) reports its scroll offset via
/// `reportsBottomBarScroll()`; `LibraryView` reads `collapsed` and builds the
/// bar accordingly — so the mini-player behaves the same everywhere.
///
/// PERFORMANCE: only `collapsed` is published, and only when it actually flips.
/// The raw offset arrives EVERY scroll frame; publishing it (as before) made
/// every observer — the whole LibraryView, including its sorted grid — re-render
/// per frame, which was the main scroll stutter.
@MainActor
final class BottomBarState: ObservableObject {
    static let shared = BottomBarState()
    private init() {}

    /// True while the bottom zone should show its compact row.
    @Published private(set) var collapsed = false

    /// Raw state, deliberately NOT published (changes every frame).
    private var scrollY: CGFloat = 0
    /// A home tap expands again; the next scroll re-enables collapsing.
    private var forceExpanded = false

    func report(_ y: CGFloat) {
        scrollY = y
        if forceExpanded { forceExpanded = false }
        applyCollapsed()
    }

    func expand() {
        forceExpanded = true
        applyCollapsed()
    }

    /// On a tab switch: expand (avoid the stale offset of the other surface).
    func reset() {
        scrollY = 0
        forceExpanded = false
        applyCollapsed()
    }

    /// Threshold gate: publish only on an actual flip.
    private func applyCollapsed() {
        let newValue = scrollY > 60 && !forceExpanded
        if newValue != collapsed { collapsed = newValue }
    }
}

extension View {
    /// Attach to EVERY scrolled surface — reports the offset to the bottom zone.
    func reportsBottomBarScroll() -> some View {
        onScrollGeometryChange(for: CGFloat.self) { $0.contentOffset.y } action: { _, y in
            BottomBarState.shared.report(y)
        }
    }
}
