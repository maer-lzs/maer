// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import SwiftUI
import Combine
import os

/// Shared state of the collapsible bottom zone. Every scrolled surface of the
/// app (library, podcast home, detail pages) reports its scroll offset via
/// `reportsBottomBarScroll()`; `LibraryView` reads `collapsed` and builds the
/// bar accordingly. So the mini-player behaves the same everywhere.
///
/// PERFORMANCE: only `collapsed` is published, and only when it actually flips.
/// The raw offset arrives EVERY scroll frame; publishing it (as before) made
/// every observer (the whole LibraryView, including its sorted grid) re-render
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
    /// Deceleration frames keep reporting offsets after the tap. Clearing on
    /// any report made the expand snap back instantly while the list was
    /// still rolling out.
    private var forceExpanded = false
    private var userDragging = false
    /// After the scroll comes fully to rest, re-expand the bar so the
    /// mini-player returns without a tab switch. Cancelled the moment scrolling
    /// resumes. X21: shortened from 1.5 s → 0.9 s so the bar returns sooner.
    private var idleExpandTask: Task<Void, Never>?
    private let idleExpandDelay: Duration = .milliseconds(900)

    /// Instant the current scroll gesture began. The collapse morph is held
    /// back until `collapseDelaySeconds` past this, so it does not fire right at
    /// scroll-start. The hitch was traced to a LAYOUT SHIFT, not to this flip.
    /// The signpost below stays as standing instrumentation for device
    /// traces, not because the question is still open.
    private var scrollStartedAt: Date = .distantPast
    /// True once a USER gesture drove the current surface's scrolling.
    /// Cleared on reset(). Collapsing requires it: pushed pages emit large
    /// layout-driven offsets while populating (the album page reported ~1400 pt
    /// without any touch), and those must never collapse the bar.
    private var hasUserScrolled = false
    /// How long after scroll-start the bar may collapse. Internal so tests
    /// can zero it out; app default 0.2 s (X21c: 0.4 s felt sluggish).
    var collapseDelaySeconds: TimeInterval = 0.2
    /// Report-driven RE-flips are blocked while the previous flip's
    /// morph still runs AND the offset has barely moved since. The morph's own
    /// residual geometry perturbation (a few pt) cannot feed back into a new
    /// decision, while a GENUINE quick direction change (a real swipe moves the
    /// offset far) passes. `expand()`/`reset()` bypass as before. Internal so
    /// tests can tune them; cooldown ~the longest morph spring + margin.
    var flipCooldownSeconds: TimeInterval = 0.7
    /// Below this offset distance from the last flip a re-flip counts as
    /// perturbation, not intent.
    var reflipPerturbationDistance: CGFloat = 44
    private var lastFlip: Date = .distantPast
    private var scrollYAtLastFlip: CGFloat = 0

    /// Signpost each `collapsed` flip so a device Instruments trace can
    /// correlate the collapse/expand morphs with scroll hitches.
    private static let signpostLog = OSLog(subsystem: "de.lzs.ABSPlayer", category: "BottomBar")

    // MARK: - Layout-shift gate (shared across all library tabs)

    /// True from the first user drag until the scroll fully rests. The window
    /// in which arriving background data must NOT reshape the visible content
    /// (sections growing in under the finger read as a "hitch" even at a
    /// perfect frame rate).
    private(set) var scrollActiveForLayout = false
    private var calmQueue: [@MainActor () -> Void] = []

    /// Content updates that can GROW/move sections route through here (tab
    /// parity. ONE mechanism for every library): applied immediately while
    /// calm, queued during an active scroll and flushed in order when the
    /// scroll rests or the surface resets (tab switch).
    func runWhenCalm(_ block: @escaping @MainActor () -> Void) {
        if scrollActiveForLayout {
            calmQueue.append(block)
        } else {
            block()
        }
    }

    private func flushCalmQueue() {
        scrollActiveForLayout = false
        guard !calmQueue.isEmpty else { return }
        let blocks = calmQueue
        calmQueue = []
        for block in blocks { block() }
    }

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
            scrollActiveForLayout = true              // layout-shift gate opens
            if started { scrollStartedAt = Date() }   // X21: reset the collapse delay
            idleExpandTask?.cancel()   // active scroll → drop any pending expand
            if forceExpanded { forceExpanded = false; applyCollapsed() }
        }
    }

    /// The scroll view reached `.idle` (finger up AND deceleration done).
    /// Schedule the auto-expand; a fresh drag cancels it via `setUserDragging`.
    func scrollDidRest() {
        armCollapseWatchdog()
        flushCalmQueue()   // scroll settled → apply deferred content updates
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

    /// WATCHDOG against a stuck collapse. The auto-expand hangs on
    /// `scrollDidRest()`, which rides the scroll-phase change to `.idle`. If
    /// that event never arrives. A surface that stops reporting mid-gesture,
    /// a phase the system skips. `collapsed` stays true, and with it the
    /// toolbar icons stay invisible AND untappable (`allowsHitTesting`). That
    /// is the reported "the button does nothing" class, and it deserves a
    /// belt rather than a hunt for the one missing event: after this long
    /// without a drag, the bar expands regardless of who forgot to report.
    private var watchdogTask: Task<Void, Never>?
    private static let watchdogDelay = Duration.seconds(4)

    func armCollapseWatchdog() {
        watchdogTask?.cancel()
        guard collapsed else { return }
        watchdogTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.watchdogDelay)
            guard let self, !Task.isCancelled, !self.userDragging, self.collapsed else { return }
            Logger.library.notice("BOTTOMBAR watchdog: collapse stuck without a drag — expanding")
            self.expand()
        }
    }

    /// On a tab switch: expand (avoid the stale offset of the other surface).
    /// Also clears `userDragging`. The outgoing surface stops reporting the
    /// moment it goes inactive (see `reportsBottomBarScroll(active:)`), so its
    /// final `.tracking → .idle` phase change may never arrive; leaving the flag
    /// set would strand the auto-expand.
    func reset() {
        flushCalmQueue()   // the fresh surface starts with settled content
        idleExpandTask?.cancel()
        scrollY = 0
        forceExpanded = false
        userDragging = false
        hasUserScrolled = false   // Y31: the fresh surface starts gesture-less
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
        // A re-flip within the morph window that the offset barely
        // moved for is the morph's own perturbation. Swallow it. Genuine
        // moves (real swipes) and explicit expands pass.
        if !forceExpanded,
           Date().timeIntervalSince(lastFlip) < flipCooldownSeconds,
           abs(scrollY - scrollYAtLastFlip) < reflipPerturbationDistance { return }
        lastFlip = Date()
        scrollYAtLastFlip = scrollY
        collapsed = newValue
        os_signpost(.event, log: Self.signpostLog, name: "barCollapsedFlip",
                    "%{public}s", newValue ? "collapse" : "expand")
    }

    /// X21 (pure/testable): the bar collapses when scrolled past the threshold,
    /// not force-expanded, AND at least `collapseDelay` past scroll start.
    /// Expanding (scrolled back up / force-expanded) is immediate. Only the
    /// collapse is delayed, to move its morph off the scroll-start moment.
    /// X21b hysteresis: the delay gates ONLY the expanded→collapsed transition.
    /// An already collapsed bar stays collapsed while past the threshold. A
    /// fresh gesture resets the scroll-start clock, and without this the delay
    /// window briefly read as "expand", making the bar flutter open and shut on
    /// every touch. Expanding happens only by scrolling back under the
    /// threshold, force-expand, or the idle auto-expand.
    /// Collapsing additionally requires that a USER gesture drove the
    /// scrolling. Programmatic/layout offsets (pushed pages populating) never
    /// collapse; expanding stays immediate as before.
    static func shouldCollapse(scrollY: CGFloat, forceExpanded: Bool, alreadyCollapsed: Bool,
                               hasUserScrolled: Bool,
                               elapsedSinceScrollStart: TimeInterval, collapseDelay: TimeInterval) -> Bool {
        guard scrollY > 60, !forceExpanded, hasUserScrolled else { return false }
        return alreadyCollapsed || elapsedSinceScrollStart >= collapseDelay
    }
}

extension View {
    /// Attach to EVERY scrolled surface. Reports the offset to the bottom zone.
    ///
    /// `active`: only the CURRENTLY VISIBLE tab may report. Hidden tabs stay
    /// mounted (see `tabVisibility`) and their scroll views keep emitting
    /// geometry/phase events; if they all fed the shared `BottomBarState`, a tab
    /// switch left the outgoing tab (still at its old offset) fighting the
    /// incoming one over `collapsed`. That oscillation restarted the bar's
    /// collapse spring + matchedGeometry morph every flip, and the morph
    /// perturbed scroll geometry into more reports. A runaway loop that froze
    /// the UI. Gating reporting to the visible tab breaks
    /// it at the root. Pushed detail pages keep the default (they live in the
    /// active tab's stack, never a second competing root).
    /// The reporter has NO part in the tile-row hang. Measured variants.
    /// Callback guard (this form), constant transform on inactive tabs,
    /// modifiers not installed at all. All hung identically with the row in
    /// a lazy tab root, and the sample shows a pure LazyStack placement loop
    /// WITHOUT the reporter in the cycle. The root was the podcast tab's
    /// outer LazyVStack (see PodcastsView); the simplest reporting form
    /// stays.
    func reportsBottomBarScroll(active: Bool = true) -> some View {
        onScrollGeometryChange(for: CGFloat.self) { $0.contentOffset.y } action: { _, y in
            guard active else { return }
            BottomBarState.shared.report(y)
        }
        .onScrollPhaseChange { _, newPhase in
            guard active else { return }
            BottomBarState.shared.setUserDragging(newPhase == .tracking || newPhase == .interacting)
            // Fully at rest → schedule the auto-expand.
            if newPhase == .idle { BottomBarState.shared.scrollDidRest() }
        }
    }
}


/// HITCH ROOT (26.07): the ONE observing leaf for `BottomBarState.collapsed`.
/// A container that carries scroll content must NEVER observe the bar state.
/// LibraryView hosts all five tab trees, so its `@ObservedObject` meant every
/// collapse flip re-evaluated every mounted tab mid-scroll (the bump that
/// survived all five part-effect bisect switches). Only this tiny wrapper
/// observes; the flip invalidates just the bar zone / the toolbar icon that
/// actually renders the state, passed down as a plain value.
struct BottomBarCollapseReader<Content: View>: View {
    @ObservedObject private var bottomBar = BottomBarState.shared
    @ViewBuilder let content: (_ collapsed: Bool) -> Content

    var body: some View {
        content(bottomBar.collapsed)
    }
}
