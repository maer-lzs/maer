// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later

#if canImport(Testing)
import Testing
import Combine
import CoreGraphics
@testable import ABSPlayer

/// P1 regression: the bottom bar publishes ONLY when `collapsed` actually
/// flips — publishing the raw offset every scroll frame was the main scroll
/// stutter (whole-library re-render per frame).
@MainActor
struct BottomBarStateTests {

    /// Counts objectWillChange emissions while running `body`.
    private func publishCount(of state: BottomBarState, during body: () -> Void) -> Int {
        var count = 0
        let sub = state.objectWillChange.sink { _ in count += 1 }
        body()
        sub.cancel()
        return count
    }

    @Test func collapsesExactlyAboveThreshold() {
        let state = BottomBarState()
        state.collapseDelaySeconds = 0
        state.setUserDragging(true)   // Y31: only user scrolling may collapse
        state.report(60)
        #expect(!state.collapsed)   // 60 is not > 60
        state.report(61)
        #expect(state.collapsed)
        state.report(10)
        #expect(!state.collapsed)
    }

    @Test("Scroll frames without a state flip publish NOTHING")
    func publishesOnlyOnFlip() {
        let state = BottomBarState()
        state.collapseDelaySeconds = 0
        state.setUserDragging(true)   // Y31 gesture gate
        // Many below-threshold frames: zero publishes.
        let below = publishCount(of: state) {
            for y in stride(from: 0.0, to: 60.0, by: 5) { state.report(y) }
        }
        #expect(below == 0)
        // Crossing up publishes exactly once, further frames above don't.
        let crossUp = publishCount(of: state) {
            for y in stride(from: 61.0, to: 500.0, by: 20) { state.report(y) }
        }
        #expect(crossUp == 1)
        // Crossing back down publishes exactly once.
        let crossDown = publishCount(of: state) {
            state.report(30)
            state.report(20)
        }
        #expect(crossDown == 1)
    }

    @Test("expand() opens the bar even while scrolled down; the next USER drag collapses again")
    func expandAndRecollapse() {
        let state = BottomBarState()
        state.collapseDelaySeconds = 0   // X21: test the threshold, not the delay
        state.setUserDragging(true)
        state.report(200)
        #expect(state.collapsed)
        state.setUserDragging(false)
        state.expand()
        #expect(!state.collapsed)
        // Deceleration keeps reporting after the tap — the expand must hold.
        state.report(210)
        state.report(240)
        #expect(!state.collapsed)
        // A new user drag re-enables collapsing.
        state.setUserDragging(true)
        #expect(state.collapsed)
    }

    @Test("reset() (tab switch) expands and clears the stale offset")
    func resetExpands() {
        let state = BottomBarState()
        state.collapseDelaySeconds = 0
        state.setUserDragging(true)
        state.report(500)
        #expect(state.collapsed)
        state.reset()
        #expect(!state.collapsed)
        // After reset a small scroll below the threshold must not collapse.
        state.report(30)
        #expect(!state.collapsed)
    }

    /// s16b: the freeze fix gates reporting to the visible tab, so the outgoing
    /// tab's final `.tracking → .idle` phase change may never arrive. `reset()`
    /// must therefore clear `userDragging` itself — otherwise the flag stays
    /// stranded from the old tab and a subsequent expand is undone the moment a
    /// high offset is reported (deceleration/geometry frames), snapping the bar
    /// collapsed on the fresh tab. Fails without the `userDragging = false` in
    /// reset().
    @Test("reset() clears the drag flag so a post-switch expand is not undone")
    func resetClearsDragFlag() {
        let state = BottomBarState()
        state.collapseDelaySeconds = 0   // X21: test the threshold, not the delay
        state.setUserDragging(true)   // outgoing tab was being dragged
        state.report(300)
        #expect(state.collapsed)
        state.reset()                 // tab switch: expand + clear drag
        state.expand()                // new tab opens the bar (e.g. auto-expand)
        #expect(!state.collapsed)
        // A high offset arrives without an active drag. With a stranded drag
        // flag this would clear forceExpanded and collapse; it must hold open.
        state.report(300)
        #expect(!state.collapsed)
    }

    /// X21: the collapse is held back until the delay past scroll start; expanding
    /// is never delayed.
    @Test("shouldCollapse: below threshold / force-expanded / within the delay do NOT collapse")
    func collapseDelayDecision() {
        // Past threshold and past the delay → collapse.
        #expect(BottomBarState.shouldCollapse(scrollY: 100, forceExpanded: false, alreadyCollapsed: false,
                                              hasUserScrolled: true,
                                              elapsedSinceScrollStart: 0.5, collapseDelay: 0.4))
        // Past threshold but still WITHIN the delay → not yet.
        #expect(!BottomBarState.shouldCollapse(scrollY: 100, forceExpanded: false, alreadyCollapsed: false,
                                               hasUserScrolled: true,
                                               elapsedSinceScrollStart: 0.1, collapseDelay: 0.4))
        // Below the threshold → never.
        #expect(!BottomBarState.shouldCollapse(scrollY: 40, forceExpanded: false, alreadyCollapsed: false,
                                               hasUserScrolled: true,
                                               elapsedSinceScrollStart: 1.0, collapseDelay: 0.4))
        // Force-expanded wins even past the delay.
        #expect(!BottomBarState.shouldCollapse(scrollY: 100, forceExpanded: true, alreadyCollapsed: false,
                                               hasUserScrolled: true,
                                               elapsedSinceScrollStart: 1.0, collapseDelay: 0.4))
    }

    /// X21b: the delay gates ONLY expanded→collapsed. An already collapsed bar
    /// must stay collapsed inside the delay window (a fresh gesture resets the
    /// scroll-start clock — without hysteresis the bar fluttered open and shut
    /// on every touch), and still expand immediately below the threshold.
    @Test("shouldCollapse hysteresis: a collapsed bar ignores the delay window")
    func collapseHysteresis() {
        // Collapsed + past threshold + WITHIN the delay → stays collapsed.
        #expect(BottomBarState.shouldCollapse(scrollY: 100, forceExpanded: false, alreadyCollapsed: true,
                                              hasUserScrolled: true,
                                              elapsedSinceScrollStart: 0.0, collapseDelay: 0.4))
        // Collapsed + back under the threshold → expands regardless of the delay.
        #expect(!BottomBarState.shouldCollapse(scrollY: 40, forceExpanded: false, alreadyCollapsed: true,
                                               hasUserScrolled: true,
                                               elapsedSinceScrollStart: 0.0, collapseDelay: 0.4))
        // Collapsed + force-expand → expands.
        #expect(!BottomBarState.shouldCollapse(scrollY: 100, forceExpanded: true, alreadyCollapsed: true,
                                               hasUserScrolled: true,
                                               elapsedSinceScrollStart: 1.0, collapseDelay: 0.4))
    }

    /// Y31: layout/programmatic offsets (a pushed page populating) must NEVER
    /// collapse the bar — only user scrolling may. The album page reported
    /// ~1400 pt without any touch and stranded the bar collapsed (the isolated
    /// harness failure).
    @Test("offsets without a user gesture never collapse; a gesture then does")
    func layoutOffsetsDoNotCollapse() {
        let state = BottomBarState()
        state.collapseDelaySeconds = 0
        state.report(1400)               // populating layout, no gesture
        #expect(!state.collapsed)
        state.report(300)
        #expect(!state.collapsed)
        state.setUserDragging(true)      // now a real scroll
        state.report(301)
        #expect(state.collapsed)
        // reset() (tab switch / new surface) clears the gesture flag again.
        state.reset()
        state.report(900)
        #expect(!state.collapsed)
        #expect(BottomBarState.shouldCollapse(scrollY: 900, forceExpanded: false,
                                              alreadyCollapsed: false, hasUserScrolled: false,
                                              elapsedSinceScrollStart: 99, collapseDelay: 0.2) == false)
    }

    /// X21b (stateful): collapsed bar + a NEW gesture at scrollY > threshold —
    /// the bar must stay collapsed through the entire delay window instead of
    /// briefly expanding (the flutter regression).
    @Test("a new gesture on a collapsed bar does not re-expand it")
    func newGestureKeepsCollapsed() {
        let state = BottomBarState()
        state.collapseDelaySeconds = 0
        state.setUserDragging(true)
        state.report(200)
        #expect(state.collapsed)
        state.setUserDragging(false)
        // New gesture with an effectively infinite delay window: without
        // hysteresis every report below would read "expand".
        state.collapseDelaySeconds = 3600
        state.setUserDragging(true)   // resets the scroll-start clock
        let publishes = publishCount(of: state) {
            state.report(210)
            state.report(260)
            state.report(320)
        }
        #expect(state.collapsed)
        #expect(publishes == 0)       // no flutter: not a single flip published
        // Scrolling back under the threshold still expands immediately.
        state.report(10)
        #expect(!state.collapsed)
    }
}
#endif
