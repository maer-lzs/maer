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
    /// Internal (not private) so tests can exercise fresh instances; the app
    /// itself only ever uses `shared`.
    init() {}

    /// True while the bottom zone should show its compact row.
    @Published private(set) var collapsed = false

    /// Raw state, deliberately NOT published (changes every frame).
    private var scrollY: CGFloat = 0
    /// A home tap expands again; the next USER drag re-enables collapsing.
    /// Deceleration frames keep reporting offsets after the tap — clearing on
    /// any report made the expand snap back instantly while the list was
    /// still rolling out.
    private var forceExpanded = false
    private var userDragging = false
    /// S10: after the scroll comes fully to rest, re-expand the bar so the
    /// mini-player returns without a tab switch. Cancelled the moment scrolling
    /// resumes. Tunable idle delay.
    private var idleExpandTask: Task<Void, Never>?
    private let idleExpandDelay: Duration = .seconds(1.5)

    func report(_ y: CGFloat) {
        scrollY = y
        if forceExpanded, userDragging { forceExpanded = false }
        applyCollapsed()
    }

    /// Scroll-phase channel: true while the user's finger drives the scroll.
    func setUserDragging(_ dragging: Bool) {
        userDragging = dragging
        if dragging {
            idleExpandTask?.cancel()   // active scroll → drop any pending expand
            if forceExpanded { forceExpanded = false; applyCollapsed() }
        }
    }

    /// S10: the scroll view reached `.idle` (finger up AND deceleration done).
    /// Schedule the auto-expand; a fresh drag cancels it via `setUserDragging`.
    func scrollDidRest() {
        idleExpandTask?.cancel()
        guard collapsed else { return }
        idleExpandTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: self?.idleExpandDelay ?? .seconds(1.5))
            guard let self, !Task.isCancelled, !self.userDragging else { return }
            self.expand()
        }
    }

    func expand() {
        forceExpanded = true
        applyCollapsed()
    }

    /// On a tab switch: expand (avoid the stale offset of the other surface).
    func reset() {
        idleExpandTask?.cancel()
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
        .onScrollPhaseChange { _, newPhase in
            BottomBarState.shared.setUserDragging(newPhase == .tracking || newPhase == .interacting)
            // S10: fully at rest → schedule the auto-expand.
            if newPhase == .idle { BottomBarState.shared.scrollDidRest() }
        }
    }
}
