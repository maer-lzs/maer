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

    @Test("expand() opens the bar even while scrolled down; the next scroll collapses again")
    func expandAndRecollapse() {
        let state = BottomBarState()
        state.report(200)
        #expect(state.collapsed)
        state.expand()
        #expect(!state.collapsed)
        // Any further scroll report clears the force-expand.
        state.report(210)
        #expect(state.collapsed)
    }

    @Test("reset() (tab switch) expands and clears the stale offset")
    func resetExpands() {
        let state = BottomBarState()
        state.report(500)
        #expect(state.collapsed)
        state.reset()
        #expect(!state.collapsed)
        // After reset a small scroll below the threshold must not collapse.
        state.report(30)
        #expect(!state.collapsed)
    }
}
#endif
