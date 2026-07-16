#if canImport(Testing)
import Testing
@testable import ABSPlayer

/// V8: the Live Activity + home widget share one cover file; it must be
/// rewritten exactly on an item change so the activity never shows a stale cover
/// next to a new title.
@MainActor
struct WidgetCoverRewriteTests {
    @Test("cover is rewritten on the first item and on every change, not for the same item")
    func rewriteOnItemChange() {
        #expect(PlayerViewModel.coverNeedsRewrite(previous: nil, current: "a"))     // first item
        #expect(PlayerViewModel.coverNeedsRewrite(previous: "a", current: "b"))     // changed
        #expect(!PlayerViewModel.coverNeedsRewrite(previous: "a", current: "a"))    // same → no rewrite
    }
}
#endif
