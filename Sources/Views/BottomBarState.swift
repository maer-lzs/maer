import SwiftUI
import Combine
import os

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

    /// Etappe 5: true while a scroll is in flight (finger drag OR deceleration).
    /// The bottom bar reduces its expensive Liquid-Glass to a cheap material then,
    /// cutting the scroll hitch (the glass re-samples the scrolling cover-rich
    /// backdrop every frame). Published ONLY at scroll START/STOP boundaries, not
    /// per frame, so it does not reintroduce per-frame re-renders.
    @Published private(set) var isScrolling = false

    func setScrolling(_ scrolling: Bool) {
        if isScrolling != scrolling { isScrolling = scrolling }
    }

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
    /// resumes. X21: shortened from 1.5 s → 0.9 s so the bar returns sooner.
    private var idleExpandTask: Task<Void, Never>?
    private let idleExpandDelay: Duration = .milliseconds(900)

    /// X21: instant the current scroll gesture began — the collapse morph is held
    /// back until `collapseDelaySeconds` past this, so it does not fire right at
    /// scroll-start (a suspected scroll-hitch source, being diagnosed via the
    /// signpost below).
    private var scrollStartedAt: Date = .distantPast
    /// Y31: true once a USER gesture drove the current surface's scrolling —
    /// cleared on reset(). Collapsing requires it: pushed pages emit large
    /// layout-driven offsets while populating (the album page reported ~1400 pt
    /// without any touch), and those must never collapse the bar.
    private var hasUserScrolled = false
    /// X21: how long after scroll-start the bar may collapse. Internal so tests
    /// can zero it out; app default 0.2 s (X21c: 0.4 s felt sluggish).
    var collapseDelaySeconds: TimeInterval = 0.2

    /// X21: signpost each `collapsed` flip so a device Instruments trace can
    /// correlate the collapse/expand morphs with scroll hitches.
    private static let signpostLog = OSLog(subsystem: "de.lzs.ABSPlayer", category: "BottomBar")

    func report(_ y: CGFloat) {
        scrollY = y
        if forceExpanded, userDragging { forceExpanded = false }
        applyCollapsed()
    }

    /// Scroll-phase channel: true while the user's finger drives the scroll.
    func setUserDragging(_ dragging: Bool) {
        let started = dragging && !userDragging   // idle → dragging = a new scroll
        userDragging = dragging
        if dragging {
            hasUserScrolled = true                    // Y31: a real gesture happened
            if started { scrollStartedAt = Date() }   // X21: reset the collapse delay
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
    /// Also clears `userDragging` — the outgoing surface stops reporting the
    /// moment it goes inactive (see `reportsBottomBarScroll(active:)`), so its
    /// final `.tracking → .idle` phase change may never arrive; leaving the flag
    /// set would strand the auto-expand.
    func reset() {
        idleExpandTask?.cancel()
        scrollY = 0
        forceExpanded = false
        userDragging = false
        hasUserScrolled = false   // Y31: the fresh surface starts gesture-less
        isScrolling = false
        applyCollapsed()
    }

    /// Threshold gate: publish only on an actual flip.
    private func applyCollapsed() {
        let elapsed = Date().timeIntervalSince(scrollStartedAt)
        let newValue = Self.shouldCollapse(scrollY: scrollY, forceExpanded: forceExpanded,
                                           alreadyCollapsed: collapsed,
                                           hasUserScrolled: hasUserScrolled,
                                           elapsedSinceScrollStart: elapsed,
                                           collapseDelay: collapseDelaySeconds)
        guard newValue != collapsed else { return }
        collapsed = newValue
        os_signpost(.event, log: Self.signpostLog, name: "barCollapsedFlip",
                    "%{public}s", newValue ? "collapse" : "expand")
    }

    /// X21 (pure/testable): the bar collapses when scrolled past the threshold,
    /// not force-expanded, AND at least `collapseDelay` past scroll start.
    /// Expanding (scrolled back up / force-expanded) is immediate — only the
    /// collapse is delayed, to move its morph off the scroll-start moment.
    /// X21b hysteresis: the delay gates ONLY the expanded→collapsed transition.
    /// An already collapsed bar stays collapsed while past the threshold — a
    /// fresh gesture resets the scroll-start clock, and without this the delay
    /// window briefly read as "expand", making the bar flutter open and shut on
    /// every touch. Expanding happens only by scrolling back under the
    /// threshold, force-expand, or the idle auto-expand.
    /// Y31: collapsing additionally requires that a USER gesture drove the
    /// scrolling — programmatic/layout offsets (pushed pages populating) never
    /// collapse; expanding stays immediate as before.
    static func shouldCollapse(scrollY: CGFloat, forceExpanded: Bool, alreadyCollapsed: Bool,
                               hasUserScrolled: Bool,
                               elapsedSinceScrollStart: TimeInterval, collapseDelay: TimeInterval) -> Bool {
        guard scrollY > 60, !forceExpanded, hasUserScrolled else { return false }
        return alreadyCollapsed || elapsedSinceScrollStart >= collapseDelay
    }
}

extension View {
    /// Attach to EVERY scrolled surface — reports the offset to the bottom zone.
    ///
    /// `active`: only the CURRENTLY VISIBLE tab may report. Hidden tabs stay
    /// mounted (see `tabVisibility`) and their scroll views keep emitting
    /// geometry/phase events; if they all fed the shared `BottomBarState`, a tab
    /// switch left the outgoing tab (still at its old offset) fighting the
    /// incoming one over `collapsed`. That oscillation restarted the bar's
    /// collapse spring + matchedGeometry morph every flip, and the morph
    /// perturbed scroll geometry into more reports — a runaway loop that froze
    /// the UI (see s16b-hitch-status). Gating reporting to the visible tab breaks
    /// it at the root. Pushed detail pages keep the default (they live in the
    /// active tab's stack, never a second competing root).
    func reportsBottomBarScroll(active: Bool = true) -> some View {
        onScrollGeometryChange(for: CGFloat.self) { $0.contentOffset.y } action: { _, y in
            guard active else { return }
            BottomBarState.shared.report(y)
        }
        .onScrollPhaseChange { _, newPhase in
            guard active else { return }
            BottomBarState.shared.setUserDragging(newPhase == .tracking || newPhase == .interacting)
            // Etappe 5: scroll in flight (drag OR deceleration) → reduce bar glass.
            BottomBarState.shared.setScrolling(newPhase != .idle)
            // S10: fully at rest → schedule the auto-expand.
            if newPhase == .idle { BottomBarState.shared.scrollDidRest() }
        }
    }
}
